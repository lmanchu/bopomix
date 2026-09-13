// Copyright (c) 2026 and onwards The Bopomix Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import XCTest

@testable import Bopomix

/// KeyHandler-level integration tests for P3 English prediction + Tab
/// completion (see the design notes' F3 scope).
/// Mirrors MixedScriptKeyHandlerTests' approach (drive the real KeyHandler
/// FSM, not the engine in isolation) for the same reason P1's review found:
/// every interesting interaction here is with candidate-window/Tab/grid
/// plumbing that the engine-level LatinLexicon/MixedScriptTracker tests
/// cannot see.
///
/// Word choice: assertions about *which* word wins a completion prefer
/// dynamic capture (read the tooltip/candidate list, then assert on what
/// was captured) over hard-coding a specific dictionary word, since the
/// ranking data (SCOWL tiers) is not something a test should be pinned to
/// -- see MixedScriptKeyHandlerTests' composingBufferAfterTypingFresh()
/// for the same reasoning. Cross-test lexicon pollution (an explicit
/// Tab/candidate pick used to permanently promote a word into every later
/// test sharing this process, docs/REVERIFY-P1-2026-09-10.md's R12) no
/// longer constrains word choice here: setUpWithError calls
/// LanguageModelManager.resetLatinLexiconForTesting() before every test.
class LatinCompletionKeyHandlerTests: XCTestCase {

    var handler = KeyHandler()

    private var temporaryUserDataFolder: URL?

    // Rolling state for the typing helpers below.
    private var state: InputState = InputState.Empty()
    /// Every state the handler emitted, Committing included -- what
    /// InputMethodController would call `previous`. See send(...).
    private var lastState: InputState = InputState.Empty()
    private var committedText = ""
    private var errorCount = 0

    override func setUpWithError() throws {
        // Must come before the first Preferences write: every assignment
        // below goes straight into the real
        // io.github.lmanchu.inputmethod.bopomix defaults domain, and this
        // is the only thing that puts it back -- including removing keys
        // the assignments *created* on a machine that never had them, and
        // including when a test below fails part-way through (see
        // PreferenceSandbox, docs/REVIEW-P3-2026-09-11.md's N4).
        //
        // Deliberately the *only* restore mechanism here: the previous
        // per-property save-and-write-back in tearDownWithError ran after
        // this block (XCTest runs teardown blocks first) and so put
        // UseCustomUserPhraseLocation / CustomUserPhraseLocation back into
        // a plist that had neither, every single run.
        PreferenceSandbox.install(on: self)

        Preferences.keyboardLayout = .standard
        Preferences.mixedScriptEnabled = true
        Preferences.latinCompletionEnabled = true
        Preferences.mixedScriptLatinOnSpaceForUserWords = true
        Preferences.associatedPhrasesEnabled = false
        Preferences.chineseConversionEnabled = false
        Preferences.escToCleanInputBuffer = false
        Preferences.keepReadingUponCompositionError = false
        Preferences.chooseCandidateUsingSpace = true
        // Pinned rather than left at whatever this machine's real prefs
        // currently hold: several tests below select a candidate by its
        // index in Preferences.candidateKeys.
        Preferences.candidateKeys = "123456789"

        // Anything these tests "learn" (an explicit Tab/candidate pick
        // appends to latin-user.txt) must land in a throwaway folder,
        // never in the real one on this machine. Injected into
        // LanguageModelManager directly rather than through
        // Preferences.customUserPhraseLocation: that key is shared with
        // every other process on the machine, including the installed
        // input method -- see dataFolderOverrideForTesting's doc and
        // docs/REVERIFY-P3-2026-09-12.md's P-2.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bopomix-completion-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        temporaryUserDataFolder = folder
        // Removed through a teardown block, not tearDownWithError, so a
        // failing test does not leave the folder behind in $TMPDIR.
        addTeardownBlock {
            LanguageModelManager.dataFolderOverrideForTesting = nil
            try? FileManager.default.removeItem(at: folder)
        }
        LanguageModelManager.dataFolderOverrideForTesting = folder.path

        // P3 fix #6 (see docs/REVERIFY-P1-2026-09-10.md's R12): reset the
        // process-wide Latin lexicon before every test so this file's
        // tests neither see nor leave behind pollution shared with any
        // other KeyHandler-level XCTest target in the same process.
        LanguageModelManager.resetLatinLexiconForTesting()
        LanguageModelManager.loadDataModels()
        try waitForLatinLexicon()

        handler = KeyHandler()
        handler.inputMode = .bopomofo
        resetSession()
    }

    override func tearDownWithError() throws {
        // Preferences are restored by PreferenceSandbox and the throwaway
        // folder by its own teardown block -- both installed in
        // setUpWithError, both of which run even when a test fails.
        temporaryUserDataFolder = nil
    }

    /// The Latin word lists load on a background queue (see
    /// `LanguageModelManager`'s `LTLoadMixedScriptLexicon`), so completion
    /// is simply unavailable until that finishes.
    private func waitForLatinLexicon() throws {
        let deadline = Date().addingTimeInterval(30)
        while !LanguageModelManager.latinLexiconReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if !LanguageModelManager.latinLexiconReady {
            throw XCTSkip("Latin lexicon did not finish loading in 30s")
        }
    }

    // MARK: - Typing helpers (same shape as MixedScriptKeyHandlerTests')

    private func resetSession() {
        handler.clear()
        state = InputState.Empty()
        lastState = InputState.Empty()
        committedText = ""
        errorCount = 0
    }

    @discardableResult
    private func send(
        _ text: String, charCode: UInt16, keyCode: UInt16 = 0,
        flags: NSEvent.ModifierFlags = []
    ) -> Bool {
        let input = KeyHandlerInput(
            inputText: text, keyCode: keyCode, charCode: charCode, flags: flags,
            isVerticalMode: false)
        return handler.handle(input: input, state: state) { newState in
            // InputMethodController commits the *previous* state's
            // composing buffer on the way into Empty (but not
            // EmptyIgnoringPreviousState) -- see its
            // handle(state:previous:client:) overload for Empty. Modelled
            // here so tests can see text that reaches the application
            // that way as well as through an explicit Committing state;
            // without it "the composing buffer vanished" and "the
            // composing buffer was committed" look identical from inside
            // this harness, which is how docs/REVIEW-P3-2026-09-11.md's
            // B4 measured an empty commit for a run that a real client
            // would have received.
            //
            // `lastState` tracks *every* state, Committing included,
            // exactly as InputMethodController.handle(state:client:)
            // does: an Enter emits Committing then Empty, and treating
            // the pre-Committing Inputting state as Empty's predecessor
            // would count the same text twice.
            if newState is InputState.Empty,
                !(newState is InputState.EmptyIgnoringPreviousState),
                let previous = self.lastState as? InputState.NotEmpty
            {
                self.committedText += previous.composingBuffer
            }
            self.lastState = newState

            if let committing = newState as? InputState.Committing {
                self.committedText += committing.poppedText
            }
            if !(newState is InputState.Committing) {
                self.state = newState
            }
        } errorCallback: {
            self.errorCount += 1
        }
    }

    private func type(_ keys: String) {
        for character in keys {
            let text = String(character)
            send(text, charCode: charCode(text))
        }
    }

    private func pressEnter() {
        send(" ", charCode: 13)
    }

    private func pressEsc() {
        send(" ", charCode: 27)
    }

    private func pressBackspace() {
        send(" ", charCode: 8)
    }

    private func pressTab() {
        send(" ", charCode: 0, keyCode: KeyCode.tab.rawValue)
    }

    @discardableResult
    private func pressShiftTab() -> Bool {
        send(" ", charCode: 0, keyCode: KeyCode.tab.rawValue, flags: .shift)
    }

    /// Upstream's "force English, uppercase" gesture: Shift plus a letter,
    /// which arrives with the *uppercase* charCode.
    @discardableResult
    private func pressShiftLetter(_ letter: String) -> Bool {
        let upper = letter.uppercased()
        return send(upper, charCode: charCode(upper), flags: .shift)
    }

    private var composingBuffer: String {
        (state as? InputState.NotEmpty)?.composingBuffer ?? ""
    }

    /// Everything the learn-from-typing / accept paths have written to
    /// this test's throwaway latin-user.txt, as word -> score.
    private var learnedLatinWords: [String: Int] {
        latinUserWords(in: temporaryUserDataFolder!)
    }

    private var tooltip: String {
        (state as? InputState.Inputting)?.tooltip ?? ""
    }

    /// The predicted word out of a tooltip shaped "word ⇥", or nil if the
    /// tooltip does not look like a completion prediction at all (e.g. it
    /// is empty, or it is some other tooltip like the cursor-between-
    /// readings one -- see buildInputtingState's tooltip-appending code).
    private var predictedCompletion: String? {
        guard tooltip.hasSuffix(" ⇥") else {
            return nil
        }
        return String(tooltip.dropLast(2))
    }

    /// What Tab would complete the current run to, read from the
    /// Shift+Tab candidate window rather than the prediction tooltip, and
    /// leaving the run exactly as it was found.
    ///
    /// Needed because the tooltip has a run-length floor the accept paths
    /// deliberately do not share (KeyHandler's
    /// kMinLatinRunLengthForPredictionTooltip): a two- or three-letter run
    /// still completes on Tab, it just does not advertise itself. Tests
    /// about *what* gets completed therefore have to ask the window.
    private func offeredCompletion() -> String? {
        pressShiftTab()
        defer {
            if state is InputState.ChoosingCandidate {
                pressEsc()
            }
        }
        guard let choosing = state as? InputState.ChoosingCandidate else {
            return nil
        }
        return choosing.candidates.first?.value
    }

    // MARK: - Tooltip visibility boundaries

    /// A single letter typed before Rule A has had a chance to fire (it
    /// needs a second, conflicting key -- see BopomofoShapeTrackerTest)
    /// is not a Latin run yet at all: no tooltip, regardless of whether
    /// completions would exist for it.
    func testNoTooltipForAnUnlockedSingleLetter() {
        type("s")
        XCTAssertNil(predictedCompletion, "\(state)")
    }

    /// "thq" is not a prefix of anything in the dictionary or the tech
    /// seed list (verified when this test was written), so once "th"
    /// locks the run (see MixedScriptTrackerTest.RuleA_ThIsLatinByThirdLetter)
    /// and "q" extends it, there is nothing to complete to.
    func testNoTooltipWhenNoCompletionExists() {
        type("thq")
        XCTAssertEqual(composingBuffer, "thq")
        XCTAssertNil(predictedCompletion, "\(state)")
    }

    /// "thro" locks by the 2nd letter, is not itself a dictionary entry
    /// (so the finished-word gate cannot apply), and the dictionary has
    /// several longer words starting with it -- and it is long enough to
    /// clear KeyHandler's kMinLatinRunLengthForPredictionTooltip.
    func testTooltipShowsALongerCompletionOnceTheRunIsLongEnough() {
        type("thro")
        XCTAssertEqual(composingBuffer, "thro")
        guard let predicted = predictedCompletion else {
            XCTFail("expected a completion tooltip, got: \(state)")
            return
        }
        XCTAssertTrue(predicted.hasPrefix("thro"), predicted)
        XCTAssertGreaterThan(predicted.count, 4, predicted)
    }

    /// docs/REVERIFY-P3-2026-09-12.md's "換裝前值得先修的最短清單" item 2.
    /// The tooltip used to appear from the second letter, which over 100
    /// keystrokes of ordinary words put a *wrong* word on screen 33 times
    /// to save 7 -- "the" advertising "throughput" by its second letter.
    /// The floor is display-only: Tab and Shift+Tab are things the user
    /// asked for and still work on the same short run.
    func testShortRunsCompleteOnDemandButDoNotAdvertise() {
        for shortRun in ["th", "thr"] {
            resetSession()
            type(shortRun)
            XCTAssertEqual(composingBuffer, shortRun)
            XCTAssertNil(
                predictedCompletion,
                "\(shortRun): below the tooltip floor, nothing may be shown: \(state)")

            guard let offered = offeredCompletion() else {
                XCTFail("\(shortRun): Shift+Tab must still offer completions: \(state)")
                continue
            }
            XCTAssertTrue(offered.hasPrefix(shortRun), offered)

            // And Tab still performs that same completion.
            resetSession()
            type(shortRun)
            pressTab()
            XCTAssertEqual(composingBuffer, offered)
        }
    }

    /// Turning the preference off must remove the tooltip even though
    /// mixedScript itself (and so Rule A locking) is still on.
    func testNoTooltipWhenLatinCompletionDisabled() {
        Preferences.latinCompletionEnabled = false
        type("thro")
        XCTAssertEqual(composingBuffer, "thro")
        XCTAssertNil(predictedCompletion, "\(state)")
    }

    /// P3 fix #3 (see the design notes' P3 fix #3
    /// and KeyHandler's _offeredCompletionFor:lexicon:): once a pending run is
    /// itself already a recognized word ranked at least as well as the
    /// best longer completion sharing its prefix, that counts as "the
    /// user finished typing this word" -- no prediction tooltip, and
    /// Tab/Shift+Tab both fall through to ordinary (no-completion) P1
    /// semantics rather than growing it further. "acer" is tech-seed
    /// ranked far ahead of every longer dictionary word sharing its
    /// prefix (e.g. "acerbic"), so it is a reliable example regardless of
    /// the dictionary's own SCOWL-tier data (see
    /// MixedScriptKeyHandlerTests.swift's testTabDoesNotExtendACompleteWord
    /// for the KeyHandler-level composingBuffer/lexicon-file assertions
    /// this test does not duplicate).
    func testTooltipAndTabAreBothSuppressedForAnAlreadyCompleteWord() {
        type("acer")
        XCTAssertNil(predictedCompletion, "\(state)")

        pressTab()
        XCTAssertEqual(composingBuffer, "acer")
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")

        resetSession()
        type("acer")
        pressShiftTab()
        XCTAssertFalse(
            state is InputState.ChoosingCandidate,
            "Shift+Tab must not offer completions for an already-complete word either: \(state)")
    }

    // MARK: - Tab accepts the top completion and typing continues

    func testTabAcceptsTopCompletionAndContinuesTyping() {
        type("thro")
        guard let predicted = predictedCompletion else {
            XCTFail("expected a completion tooltip, got: \(state)")
            return
        }
        pressTab()
        XCTAssertEqual(composingBuffer, predicted)
        XCTAssertNil(predictedCompletion, "no completion is longer than itself: \(state)")

        // Typing on extends the *completed* word, not the original "thro".
        type("s")
        XCTAssertEqual(composingBuffer, predicted + "s")
    }

    /// Backspacing after an accepted completion shortens the completed
    /// word, matching MixedScriptTracker's PopLastLatinCharAfterAcceptingCompletion.
    func testBackspaceAfterAcceptingCompletionShortensTheCompletedWord() {
        type("thro")
        guard let predicted = predictedCompletion else {
            XCTFail("expected a completion tooltip, got: \(state)")
            return
        }
        pressTab()
        XCTAssertEqual(composingBuffer, predicted)
        pressBackspace()
        XCTAssertEqual(composingBuffer, String(predicted.dropLast()))
    }

    /// With the run not yet long enough or not locked at all, Tab must
    /// fall through to plain P1 semantics (a no-op here, since there is
    /// nothing in the grid to cycle) rather than doing anything new.
    func testTabWithNoCompletionFallsThroughToOrdinaryTabSemantics() {
        type("thq")
        XCTAssertNil(predictedCompletion)
        pressTab()
        XCTAssertEqual(composingBuffer, "thq")
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
    }

    /// Same run, same lack of a completion, but with the preference off:
    /// must behave exactly like master (Tab is simply unhandled/no-op).
    func testTabWithCompletionDisabledMatchesMaster() {
        Preferences.latinCompletionEnabled = false
        type("th")
        pressTab()
        XCTAssertEqual(composingBuffer, "th")
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
    }

    // MARK: - Rule B: Tab flips to English, Tab again completes

    /// "coo" is one of the 15 dictionary-reachable Rule-B words (see
    /// docs/REVERIFY-P1-2026-09-10.md's R10). Its shape stays alive the
    /// whole time (rule B, not rule A), so the *first* Tab press must
    /// still do exactly what P1 always did -- flip to the English form --
    /// and only a *second* Tab press (this node now showing plain ASCII)
    /// should look for a completion.
    func testRuleBFlipThenTabCompletesFurther() {
        type("coo ")
        XCTAssertEqual(composingBuffer, "黑")
        pressTab()
        XCTAssertEqual(composingBuffer, "coo", "P1's existing Tab-flips-to-English behavior must be unchanged")

        pressTab()
        XCTAssertGreaterThan(composingBuffer.count, 3, "\(state)")
        XCTAssertTrue(composingBuffer.hasPrefix("coo"), composingBuffer)
    }

    /// "ssl" rather than "coo"/"zoo" here only because "ssl " (fed through
    /// the real BopomofoReadingBuffer, not just MixedScriptTracker) is not
    /// itself a tone-1 syllable another test in this repo already
    /// exercises -- unrelated to lexicon pollution, which
    /// resetLatinLexiconForTesting() rules out for every test regardless
    /// of word choice.
    ///
    /// The second Tab must not complete. It is free to do whatever P1's
    /// ordinary cycling does with its next candidate (which may well be
    /// an unrelated Chinese character -- that is just Tab cycling through
    /// the reading's other candidates, unrelated to this feature), so
    /// this only pins the negative: composingBuffer must never grow into
    /// something longer than "ssl" that still starts with "ssl" (the
    /// shape a completion would have).
    func testRuleBSecondTabDoesNotCompleteWhenDisabled() {
        Preferences.latinCompletionEnabled = false
        type("ssl ")
        pressTab()
        XCTAssertEqual(composingBuffer, "ssl")
        pressTab()
        XCTAssertFalse(
            composingBuffer.count > 3 && composingBuffer.hasPrefix("ssl"),
            "completion must not have run while disabled: \(composingBuffer)")
    }

    // MARK: - Shift+Tab candidate window

    func testShiftTabOpensACandidateWindowOfCompletions() {
        type("th")
        pressShiftTab()
        guard let choosing = state as? InputState.ChoosingCandidate else {
            XCTFail("expected a candidate window, got: \(state)")
            return
        }
        XCTAssertGreaterThan(choosing.candidates.count, 0)
        for candidate in choosing.candidates {
            XCTAssertTrue(candidate.value.hasPrefix("th"), candidate.value)
            XCTAssertGreaterThan(candidate.value.count, 2, candidate.value)
        }
    }

    /// Typing another letter while the window is open must re-query
    /// (narrower candidate set for the longer prefix), not close the
    /// window the way an ordinary candidate window's "any other letter
    /// cancels" behavior does (see docs/REVIEW-P1-2026-09-10.md's B3 and
    /// R2, why that behavior exists and why it must not extend here).
    func testTypingMoreLettersUpdatesTheOpenCandidateWindow() {
        type("th")
        pressShiftTab()
        guard state is InputState.ChoosingCandidate else {
            XCTFail("expected a candidate window, got: \(state)")
            return
        }

        type("r")
        guard let choosing = state as? InputState.ChoosingCandidate else {
            XCTFail("expected the window to stay open after typing a letter, got: \(state)")
            return
        }
        XCTAssertGreaterThan(choosing.candidates.count, 0)
        for candidate in choosing.candidates {
            XCTAssertTrue(candidate.value.hasPrefix("thr"), candidate.value)
        }
        // The composing buffer under the window reflects the longer run.
        XCTAssertEqual(composingBuffer, "thr")
    }

    /// Esc closes the window and returns to the plain (not completed)
    /// run -- the run itself was never touched while the window was open.
    func testEscClosesTheCandidateWindowBackToThePlainRun() {
        type("th")
        pressShiftTab()
        XCTAssertTrue(state is InputState.ChoosingCandidate, "\(state)")

        pressEsc()
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
        XCTAssertEqual(composingBuffer, "th")
    }

    /// If the longer run the user typed into the window has no
    /// completions left at all, the window closes on its own (falls back
    /// to a plain run) rather than showing an empty window.
    func testTypingIntoDeadEndClosesTheWindow() {
        type("th")
        pressShiftTab()
        XCTAssertTrue(state is InputState.ChoosingCandidate, "\(state)")

        type("q")  // "thq" has no dictionary matches at all.
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
        XCTAssertEqual(composingBuffer, "thq")
    }

    func testShiftTabDoesNothingWhenCompletionDisabled() {
        Preferences.latinCompletionEnabled = false
        type("th")
        pressShiftTab()
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
        XCTAssertEqual(composingBuffer, "th")
    }

    // MARK: - Accepting writes/bumps the use count and reorders complete()

    /// acceptLatinCompletion(value:) is the shared core both Tab and a
    /// candidate-window pick funnel through (see
    /// InputMethodController+CandidateControllerDelegate.swift's
    /// didSelectCandidateAtIndex:, which this test cannot drive directly
    /// -- it lives on the input method controller, not KeyHandler, and
    /// needs a real VTCandidateController this lightweight harness does
    /// not construct, exactly like MixedScriptKeyHandlerTests never
    /// drives an actual digit-key candidate selection either). Calling it
    /// directly still exercises the real accept path Tab uses internally
    /// (_acceptLatinCompletionWord:), just skipping the keystroke that
    /// would normally produce the value.
    func testAcceptingACompletionMakesItTheTopChoiceNextTime() {
        type("thro")
        pressShiftTab()
        guard let choosing = state as? InputState.ChoosingCandidate,
            choosing.candidates.count >= 2,
            let lastChoice = choosing.candidates.last
        else {
            XCTFail("expected a candidate window with >= 2 candidates, got: \(state)")
            return
        }
        // The *last*-ranked (worst) of the returned candidates: guaranteed
        // not to already be the top choice, so this test can actually
        // prove accepting it moved it there.
        let chosenWord = lastChoice.value
        pressEsc()

        resetSession()
        type("thro")
        XCTAssertNotEqual(
            predictedCompletion, chosenWord,
            "test setup: pick a candidate that was not already on top")

        handler.acceptLatinCompletion(value: chosenWord)

        resetSession()
        type("thro")
        XCTAssertEqual(predictedCompletion, chosenWord)
    }

    /// Accepting the same word twice bumps its count rather than just
    /// re-recording membership -- verified indirectly (LatinLexiconTest's
    /// RememberWordCountsRepeatedAcceptances/RememberWordRewritesExistingCountInPlace
    /// cover the counting mechanics directly): this only pins that
    /// KeyHandler's accept path is idempotent-safe to call twice in a row
    /// and the word stays the top choice.
    func testAcceptingTheSameCompletionTwiceStaysConsistent() {
        type("thro")
        pressShiftTab()
        guard let choosing = state as? InputState.ChoosingCandidate,
            choosing.candidates.count >= 2,
            let lastChoice = choosing.candidates.last
        else {
            XCTFail("expected a candidate window with >= 2 candidates, got: \(state)")
            return
        }
        let chosenWord = lastChoice.value
        pressEsc()

        handler.acceptLatinCompletion(value: chosenWord)
        handler.acceptLatinCompletion(value: chosenWord)

        resetSession()
        type("thro")
        XCTAssertEqual(predictedCompletion, chosenWord)
    }

    // MARK: - B1: the candidate window lists genuinely common words

    /// docs/REVIEW-P3-2026-09-11.md's B1. `complete()`'s top-n heap kept
    /// the wrong end of itself, so everything below the first row was
    /// whatever happened to be alphabetically first: Shift+Tab on "th"
    /// offered `thad / thaddeus / thai / thailand`, not `than / thank /
    /// that`. The engine-level regression lives in
    /// LatinLexiconTest.CompleteMatchesAFullSortForEveryPrefixAndN; this
    /// pins the user-visible end of it on the real bundled dictionary.
    ///
    /// Asserted as "every one of the first three rows is a word a person
    /// actually types" rather than a hard-coded list, because the exact
    /// words depend on the SCOWL tier data (see this file's word-choice
    /// note). A proper-noun/obscure row like "thaddeus" or "thailander"
    /// is precisely what the bug produced, so a common-word membership
    /// test is what distinguishes fixed from broken.
    ///
    /// Only prefixes with enough *ranking* signal to sort by can be held
    /// to this: see testShiftTabOnAPrefixWithNoRankingSignal below for
    /// what the bundled dictionary can and cannot do, and why that is a
    /// separate (N1) problem from this one.
    /// Named for what it checks: the *top three rows*. Rows 4 and below
    /// are still alphabetical debris on most prefixes, which is N1's
    /// unfixed ranking-data problem, not this one --
    /// testShiftTabOnAPrefixWithNoRankingSignal is where that is pinned.
    func testShiftTabTopThreeRowsAreCommonWordsNotAlphabeticalDebris() {
        let commonWordsByPrefix = [
            "th": Set([
                "than", "thank", "thanks", "that", "the", "their", "them", "then",
                "there", "these", "they", "thing", "things", "think", "this",
                "those", "though", "thought", "thread", "three", "through",
                "throughput", "throttle",
            ]),
            "pr": Set([
                "practical", "practice", "present", "press", "pretty", "price",
                "primary", "print", "private", "probably", "problem", "process",
                "produce", "product", "production", "profile", "program",
                "progress", "project", "promise", "prompt", "proper", "protect",
                "provide", "provisioning", "proxy",
            ]),
        ]

        for (prefix, commonWords) in commonWordsByPrefix {
            resetSession()
            type(prefix)
            pressShiftTab()
            guard let choosing = state as? InputState.ChoosingCandidate else {
                XCTFail("\(prefix): expected a completion candidate window, got: \(state)")
                continue
            }
            let top3 = choosing.candidates.prefix(3).map { $0.value }
            XCTAssertEqual(top3.count, 3, "\(prefix): \(choosing.candidates.map { $0.value })")
            for candidate in top3 {
                XCTAssertTrue(
                    commonWords.contains(candidate),
                    "\(prefix): \"\(candidate)\" is not a common word. "
                        + "Top rows were \(top3); full list "
                        + "\(choosing.candidates.map { $0.value })")
            }
        }
    }

    /// The honest limit of the B1 fix, pinned so nobody mistakes it for a
    /// regression later. "wh" has exactly one ranked completion (the tech
    /// seed's "whatsapp"); `whack`, `whale`, `what`, `when`, `where` and
    /// `which` are *all* SCOWL tier 0, so once the seed term is placed
    /// there is no data left to order them by and rows 2+ are whatever
    /// comes first alphabetically. That is
    /// docs/REVIEW-P3-2026-09-11.md's N1 (five coarse tiers over 141,697
    /// words, 38,784 of them in tier 0), not B1: the ordering is now
    /// provably the true top-n (LatinLexiconTest's
    /// CompleteMatchesAFullSortForEveryPrefixAndN), the ranking data is
    /// simply blind here. Fixing it needs a real frequency source, which
    /// is P4 work.
    func testShiftTabOnAPrefixWithNoRankingSignal() {
        type("wh")
        pressShiftTab()
        guard let choosing = state as? InputState.ChoosingCandidate else {
            XCTFail("expected a completion candidate window, got: \(state)")
            return
        }
        let values = choosing.candidates.map { $0.value }
        XCTAssertEqual(
            values.first, "whatsapp",
            "the one ranked completion must still come first: \(values)")
        // Everything after the ranked row is a single alphabetical run --
        // the shape a tier-0 tie produces. If a real frequency source ever
        // lands, this assertion is the one that should start failing.
        let rest = Array(values.dropFirst())
        XCTAssertEqual(rest, rest.sorted(), "expected an alphabetical tail, got \(values)")
    }

    // MARK: - B3: a finished word is not grown into something else

    /// docs/REVIEW-P3-2026-09-11.md's B3. The gate used to compare raw
    /// rank(), and every hand-ranked tech-seed term outranks every
    /// dictionary word, so finishing an ordinary English word and
    /// pressing Tab rewrote it: code -> codesign, test -> testflight,
    /// and "run" permanently advertised "runway". These five are the
    /// exact cases the review reproduced.
    func testTabLeavesAFinishedWordAloneEvenWhenASeedTermExtendsIt() throws {
        for word in ["code", "test", "run", "the", "acer"] {
            resetSession()
            type(word)
            XCTAssertEqual(composingBuffer, word)
            // Only half the story for "run"/"the", which are below the
            // tooltip's own length floor anyway; the Shift+Tab assertion
            // at the bottom of this loop is what proves the *gate* is
            // what silences them.
            XCTAssertNil(
                predictedCompletion,
                "\(word): a finished word must not advertise a completion: \(state)")
            pressTab()
            XCTAssertEqual(composingBuffer, word, "Tab must not grow \"\(word)\"")
            XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")

            resetSession()
            type(word)
            pressShiftTab()
            XCTAssertFalse(
                state is InputState.ChoosingCandidate,
                "\(word): Shift+Tab must not offer completions either: \(state)")
        }
        XCTAssertTrue(
            learnedLatinWords.isEmpty,
            "Tab over a finished word must not write anything: \(learnedLatinWords)")
    }

    /// The other side of the same gate: a run that is *not* a finished
    /// word still completes normally. "aweso" is not a dictionary entry
    /// at all, and a two-letter run is below the finished-word floor (see
    /// KeyHandler's kMinFinishedLatinWordLength) even when the dictionary
    /// happens to list it -- "pr" and "th" are both entries, and both must
    /// keep completing.
    func testAnUnfinishedRunStillCompletes() {
        type("aweso")
        XCTAssertEqual(predictedCompletion, "awesome")
        pressTab()
        XCTAssertEqual(composingBuffer, "awesome")

        // Both are dictionary entries in their own right, and both lock as
        // Rule-A runs ("co" does not -- it is a valid reading, so it stays
        // Chinese; that is Rule B's job, not this gate's). Asked through
        // the candidate window rather than the tooltip, which has its own,
        // longer floor -- what is being pinned here is the finished-word
        // gate, not the tooltip's noise budget.
        for shortRun in ["th", "pr"] {
            resetSession()
            type(shortRun)
            XCTAssertNotNil(
                offeredCompletion(),
                "\(shortRun): a short run is a prefix in progress, not a finished word: \(state)")
        }
    }

    // MARK: - B4: Shift+letter must not swallow a pending run

    /// docs/REVIEW-P3-2026-09-11.md's B4. Shift+letter is upstream's own
    /// "force English, uppercase" gesture and deliberately bypasses every
    /// mixedScript code path -- but a pending Rule-A run lives only in the
    /// tracker, so the uppercase path used to clear it away with
    /// everything else. Typing "the API" lost "the" outright.
    func testShiftLetterCommitsThePendingRunInsteadOfDroppingIt() {
        type("the")
        XCTAssertEqual(composingBuffer, "the")
        pressShiftLetter("a")
        XCTAssertEqual(
            committedText, "the",
            "the pending run must reach the application, not vanish")
        XCTAssertTrue(learnedLatinWords.keys.contains("the"))
    }

    /// Same fix with the completion candidate window open -- that path
    /// closes the window and re-dispatches the key, so it has to land on
    /// the same boundary handling.
    func testShiftLetterWithTheCandidateWindowOpenAlsoCommitsTheRun() {
        type("th")
        pressShiftTab()
        XCTAssertTrue(state is InputState.ChoosingCandidate, "\(state)")
        pressShiftLetter("a")
        XCTAssertEqual(committedText, "th")
    }

    // MARK: - B5: Tab is never handed to the application mid-composition

    /// docs/REVIEW-P3-2026-09-11.md's B5. With a pending run on screen and
    /// nothing for Tab to do, `handle(input:)` returned false, so the host
    /// application got the Tab and moved focus (or typed a tab character)
    /// while unfinished English was still showing. Asserted on the return
    /// value, which is the only thing that decides whether the key escapes.
    func testTabAndShiftTabAreAlwaysConsumedWhileARunIsPending() {
        // No completion exists at all.
        resetSession()
        type("thq")
        XCTAssertTrue(pressShiftTab(), "Shift+Tab must be consumed for \"thq\"")
        XCTAssertEqual(composingBuffer, "thq")

        // A finished word: the gate says there is nothing to offer.
        for word in ["acer", "the"] {
            resetSession()
            type(word)
            XCTAssertTrue(pressShiftTab(), "Shift+Tab must be consumed for \"\(word)\"")
            XCTAssertEqual(composingBuffer, word)
        }

        // The pre-existing correct behaviour, which must not change: with
        // nothing composing at all, Tab belongs to the application.
        resetSession()
        XCTAssertFalse(pressShiftTab(), "an empty composing buffer must not eat Tab")
    }

    // MARK: - B2: what learn-from-typing is allowed to write to disk

    /// docs/REVIEW-P3-2026-09-11.md's B2 and N5. `latinLearnTypedWords` is
    /// on by default and used to append *any* committed run of three or
    /// more letters to latin-user.txt with no dictionary check and no
    /// length cap, where -- because every user word ranked ahead of the
    /// whole dictionary -- it then owned its prefix permanently. Mutation
    /// testing found nothing guarding this at all (M2 and M4 both
    /// survived). This is the table.
    func testLearnFromTypingWritesOnlyWhatThePolicyAllows() {
        // Every eligible commit is worth exactly one sighting, whether or
        // not the dictionary has heard of the word.
        type("code ")
        XCTAssertEqual(learnedLatinWords["code"], 1)

        // A word it does not know is recorded at 1 too, however that run
        // was ended -- but 1 is below
        // LatinLexicon::kUserWordConfirmedScore, so it changes no ranking
        // and is not offered as a completion (see
        // testAnUnconfirmedTypedWordIsRecordedButNeverSuggested).
        resetSession()
        type("thq ")
        XCTAssertEqual(learnedLatinWords["thq"], 1, "space ends a run")

        resetSession()
        type("zzq,")
        XCTAssertEqual(learnedLatinWords["zzq"], 1, "punctuation ends a run")

        resetSession()
        type("xqk")
        pressEnter()
        XCTAssertEqual(learnedLatinWords["xqk"], 1, "Enter ends a run")

        // A second commit of the same string confirms it.
        resetSession()
        type("thq ")
        XCTAssertEqual(
            learnedLatinWords["thq"], 2,
            "two separate commits of the same unknown word confirm it")
        XCTAssertEqual(learnedLatinWords["zzq"], 1, "other words are unaffected")
    }

    /// docs/REVERIFY-P3-2026-09-12.md's "pending 落地". The first sighting
    /// of a word the dictionary does not know is now written to disk
    /// instead of being staged in a process-lifetime-only map -- but
    /// writing it down is not the same as recommending it. Nothing may
    /// suggest it until a second commit confirms it.
    func testAnUnconfirmedTypedWordIsRecordedButNeverSuggested() {
        type("thqzy ")
        XCTAssertEqual(learnedLatinWords["thqzy"], 1)

        resetSession()
        type("thqz")
        XCTAssertEqual(composingBuffer, "thqz")
        XCTAssertNil(
            predictedCompletion,
            "one sighting must not put the word in the tooltip: \(state)")
        XCTAssertNil(
            offeredCompletion(),
            "nor in the candidate window: \(state)")

        resetSession()
        type("thqz")
        pressTab()
        XCTAssertEqual(composingBuffer, "thqz", "nor may Tab complete to it")
    }

    /// The point of moving the staging to disk: "twice" used to mean
    /// twice *inside one process lifetime*, which a logout, an input
    /// method switch or a crash reset -- so the words that actually need
    /// learning (a name, a product, an internal codename, typed once or
    /// twice a day hours apart) never got there. resetLatinLexiconForTesting()
    /// plus a reload is the same thing a relaunch does.
    func testASecondCommitAfterARestartStillConfirmsTheWord() throws {
        type("thqzy ")
        XCTAssertEqual(learnedLatinWords["thqzy"], 1)

        LanguageModelManager.resetLatinLexiconForTesting()
        LanguageModelManager.loadDataModels()
        try waitForLatinLexicon()
        handler = KeyHandler()
        handler.inputMode = .bopomofo
        resetSession()

        type("thqzy ")
        XCTAssertEqual(
            learnedLatinWords["thqzy"], 2,
            "the sighting from before the restart must still count")

        resetSession()
        type("thqz")
        XCTAssertEqual(
            predictedCompletion, "thqzy",
            "confirmed now, so it is finally worth suggesting: \(state)")
    }

    /// A dictionary word behaves exactly as it did before the staging
    /// moved: one sighting records it without changing any ranking, two
    /// confirm it and put it ahead of the dictionary for its prefix.
    func testADictionaryWordStillNeedsTwoSightingsToOutrankTheDictionary() {
        let before = predictedCompletionAfterTyping("thro")
        XCTAssertNotEqual(before, "through", "test setup: pick a word that is not already on top")

        type("through ")
        XCTAssertEqual(learnedLatinWords["through"], 1)
        XCTAssertEqual(
            predictedCompletionAfterTyping("thro"), before,
            "one sighting of a dictionary word must not reorder anything")

        resetSession()
        type("through ")
        XCTAssertEqual(learnedLatinWords["through"], 2)
        XCTAssertEqual(predictedCompletionAfterTyping("thro"), "through")
    }

    private func predictedCompletionAfterTyping(_ run: String) -> String? {
        resetSession()
        type(run)
        let result = predictedCompletion
        resetSession()
        return result
    }

    /// The length bounds, and the 40-letter mash the review typed.
    func testLearnFromTypingRejectsRunsOutsideTheLengthBounds() {
        let mash = String(repeating: "qwrt", count: 10)
        type(mash + " ")
        type(mash + " ")
        XCTAssertNil(
            learnedLatinWords[mash],
            "a 40-letter run is past the length cap even after two sightings")

        resetSession()
        type("th ")
        XCTAssertNil(learnedLatinWords["th"], "two letters is below the floor")
    }

    /// Abandoning a run must never leave a trace. Mutation M2 (letting
    /// Esc learn too) survived the previous suite; this kills it.
    func testAbandoningARunLearnsNothing() {
        type("code")
        pressEsc()
        XCTAssertTrue(learnedLatinWords.isEmpty, "\(learnedLatinWords)")

        resetSession()
        type("code")
        for _ in 0..<4 {
            pressBackspace()
        }
        XCTAssertTrue(learnedLatinWords.isEmpty, "\(learnedLatinWords)")

        // Shift's own force-English path never touches the tracker.
        resetSession()
        for letter in ["a", "b", "c"] {
            pressShiftLetter(letter)
        }
        pressEnter()
        XCTAssertTrue(learnedLatinWords.isEmpty, "\(learnedLatinWords)")

        // Pure Chinese, obviously.
        resetSession()
        type("su3cl3")
        pressEnter()
        XCTAssertTrue(learnedLatinWords.isEmpty, "\(learnedLatinWords)")
    }

    /// Mutation M4 (dropping the preference gate) survived the previous
    /// suite: nothing asserted that turning the preference off actually
    /// stops the writes.
    func testLearnFromTypingWritesNothingWhenThePreferenceIsOff() {
        Preferences.latinLearnTypedWords = false
        type("code ")
        type("thq ")
        resetSession()
        type("thq ")
        XCTAssertTrue(
            learnedLatinWords.isEmpty,
            "latinLearnTypedWords=false must mean zero writes: \(learnedLatinWords)")
    }

    /// docs/REVIEW-P3-2026-09-11.md's N3: turning *completion* off is the
    /// intuitive way to switch P3 off, and it used to leave the
    /// learn-from-typing writes running.
    func testLearnFromTypingStopsWhenCompletionIsDisabled() {
        Preferences.latinCompletionEnabled = false
        type("code ")
        XCTAssertTrue(
            learnedLatinWords.isEmpty,
            "disabling completion must stop the disk writes too: \(learnedLatinWords)")
    }

    /// An accepted completion is a deliberate choice and confirms the word
    /// on its own -- one accept, not two, and it does not double-count
    /// when the run is then committed normally.
    func testAcceptingACompletionRecordsItOnce() {
        type("aweso")
        pressTab()
        XCTAssertEqual(composingBuffer, "awesome")
        pressEnter()
        XCTAssertEqual(learnedLatinWords["awesome"], 2)
        XCTAssertNil(learnedLatinWords["aweso"], "the abandoned prefix is not a word")
    }

    // MARK: - P-1: moving the user-phrase folder must not destroy a word list

    /// docs/REVERIFY-P3-2026-09-12.md's P-1, end to end through the real
    /// KeyHandler. Folder A has been in use for a while; the user points
    /// the preference at folder B, which already holds a `latin-user.txt`
    /// (the Dropbox case). Typing one English word used to truncate B's
    /// file and write A's entire contents over it.
    ///
    /// `LanguageModelManager.reloadLatinUserWordList()` is exactly what
    /// `AppDelegate.updateUserPhrases()` calls on
    /// `userPhraseLocationDidChange`; this test stands in for the
    /// notification, which needs a live AppDelegate this harness does not
    /// build.
    func testMovingTheUserPhraseFolderNeitherLosesNorCarriesWords() throws {
        let folderA = temporaryUserDataFolder!
        let folderB = folderA.deletingLastPathComponent()
            .appendingPathComponent("bopomix-completion-tests-B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folderB, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folderB)
        }
        try "dropboxword\t4\n".write(
            to: folderB.appendingPathComponent("latin-user.txt"),
            atomically: true, encoding: .utf8)

        // A word learned while folder A is current.
        type("code ")
        XCTAssertEqual(learnedLatinWords["code"], 1)

        // The user moves the folder.
        LanguageModelManager.dataFolderOverrideForTesting = folderB.path
        LanguageModelManager.reloadLatinUserWordList()

        resetSession()
        type("test ")

        let inB = latinUserWords(in: folderB)
        XCTAssertEqual(
            inB["dropboxword"], 4,
            "the new folder's own word list must survive: \(inB)")
        XCTAssertEqual(inB["test"], 1, "\(inB)")
        XCTAssertNil(
            inB["code"],
            "the old folder's words must not be copied into the new one: \(inB)")

        let inA = latinUserWords(in: folderA)
        XCTAssertEqual(inA, ["code": 1], "the old folder must be left untouched: \(inA)")
    }

    /// The other half of the same fix, without a folder change: another
    /// machine (or a hand edit) adds a word to the file while the input
    /// method is running. The next write must merge, not overwrite.
    func testAnExternallyEditedWordListIsMergedNotOverwritten() throws {
        type("code ")
        XCTAssertEqual(learnedLatinWords["code"], 1)

        let path = temporaryUserDataFolder!.appendingPathComponent("latin-user.txt")
        try (try String(contentsOf: path, encoding: .utf8) + "othermachine\t6\n")
            .write(to: path, atomically: true, encoding: .utf8)

        resetSession()
        type("test ")

        XCTAssertEqual(
            learnedLatinWords["othermachine"], 6,
            "a word added behind our back must survive the next write: \(learnedLatinWords)")
        XCTAssertEqual(learnedLatinWords["code"], 1)
        XCTAssertEqual(learnedLatinWords["test"], 1)
    }

    private func latinUserWords(in folder: URL) -> [String: Int] {
        let path = folder.appendingPathComponent("latin-user.txt").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var result: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard let word = fields.first else { continue }
            result[String(word)] = fields.count > 1 ? Int(fields[1]) ?? 1 : 1
        }
        return result
    }

    // MARK: - Pure Chinese: ON must equal OFF

    func testPureChineseTypingIsUnaffectedByLatinCompletion() {
        Preferences.latinCompletionEnabled = true
        type("su3cl3")
        let onResult = composingBuffer

        resetSession()
        Preferences.latinCompletionEnabled = false
        type("su3cl3")
        let offResult = composingBuffer

        XCTAssertEqual(onResult, "你好")
        XCTAssertEqual(onResult, offResult)
    }

    func testPureChineseSentenceWithToneKeysIsUnaffectedByLatinCompletion() {
        Preferences.latinCompletionEnabled = true
        type("su3cl3a945j4up gj bj4z83")
        let onResult = composingBuffer

        resetSession()
        Preferences.latinCompletionEnabled = false
        type("su3cl3a945j4up gj bj4z83")
        let offResult = composingBuffer

        XCTAssertEqual(onResult, offResult)
    }

    // MARK: - P-3: the test host must not write the developer's preferences

    /// docs/REVERIFY-P3-2026-09-12.md's P-3. The Bopomix app bundle is
    /// this suite's test host, so `main.swift` runs to completion before
    /// any test does -- and its `Preferences.populateDefaults()` wrote 23
    /// keys straight into the real
    /// `io.github.lmanchu.inputmethod.bopomix` domain, earlier than
    /// `PreferenceSandbox` can snapshot it, so the sandbox restored them
    /// instead of removing them. One of them, `AddPhraseHookPath`, was
    /// left pointing into a `build/` directory on the reviewer's machine.
    ///
    /// `main.swift` now skips that call under XCTest. There is nothing
    /// observable to assert afterwards (the whole point is that nothing
    /// happened), so what is pinned here is the predicate the skip is
    /// built on: if this ever stops being true, the guard silently stops
    /// guarding.
    func testTheHostSkipsPopulateDefaultsUnderXCTest() {
        XCTAssertTrue(
            Preferences.isRunningUnderXCTest,
            "main.swift's populateDefaults() guard depends on this being true "
                + "inside the test host")
    }

    /// The user-data folder redirection must not go through preferences
    /// at all: those are one file shared by every process on the machine,
    /// which is how a parallel run wrote 130 eval-corpus words into the
    /// developer's real latin-user.txt (P-2).
    /// Nothing in this suite writes `UseCustomUserPhraseLocation` or
    /// `CustomUserPhraseLocation` any more; the redirection is a
    /// process-local override that outranks whatever those keys happen to
    /// say on this machine.
    func testTheUserDataFolderIsRedirectedWithoutTouchingPreferences() {
        XCTAssertEqual(
            LanguageModelManager.dataFolderPath, temporaryUserDataFolder!.path)
    }

    // MARK: - eval200: how many keystrokes does completion actually save?

    private struct EvalRow {
        let englishTokens: [String]
        /// Only the key tokens belonging to the row's Chinese segments
        /// (see MixedScriptKeyHandlerTests.swift's identically-named
        /// field, which this duplicates rather than shares -- each eval
        /// test file keeps its own private corpus-loading helpers in this
        /// codebase, e.g. `charCode` aside, so does `loadCorpus`/`CorpusRow`).
        let chineseOnlyKeys: String
    }

    private func loadEvalRows(at path: String) throws -> [EvalRow] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [EvalRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 6 else {
                XCTFail("expected 6 TSV columns, got \(parts.count)")
                continue
            }
            guard let data = parts[2].data(using: .utf8),
                let segments = try JSONSerialization.jsonObject(with: data)
                    as? [[String: String]]
            else {
                XCTFail("could not parse segments for row \(parts[0])")
                continue
            }

            let keyTokens = parts[4].components(separatedBy: " ")
            let chineseReadings = parts[3].isEmpty ? [] : parts[3].components(separatedBy: "|")
            var tokenIndex = 0
            var chineseSegmentIndex = 0
            var chineseKeyTokens: [String] = []
            for segment in segments {
                if segment["lang"] == "zh" {
                    guard chineseSegmentIndex < chineseReadings.count else { break }
                    let count = chineseReadings[chineseSegmentIndex]
                        .components(separatedBy: " ").count
                    chineseSegmentIndex += 1
                    let end = min(tokenIndex + count, keyTokens.count)
                    chineseKeyTokens.append(contentsOf: keyTokens[tokenIndex..<end])
                    tokenIndex = end
                } else {
                    tokenIndex += 1
                }
            }

            rows.append(
                EvalRow(
                    englishTokens: segments.filter { $0["lang"] == "en" }.compactMap {
                        $0["text"]
                    },
                    chineseOnlyKeys: chineseKeyTokens.joined(separator: " ")))
        }
        return rows
    }

    /// build_corpus.py's `keys` column puts a delimiter space after every
    /// syllable including tone-digit-finished ones; see
    /// MixedScriptKeyHandlerTests.swift's humanTypedKeys for why those
    /// (and only those) are dropped before typing.
    private func humanTypedKeys(_ keys: String) -> String {
        var result = ""
        var previous: Character?
        for character in keys {
            if character == " ", let p = previous, "3467".contains(p) {
                previous = character
                continue
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// One token's per-letter completability simulation, shared by both
    /// the plain and "with history" passes below. Types `token` (lowered
    /// first -- P3 fix #4: Shift-typed uppercase takes the separate,
    /// unrelated upstream "force English" path that never touches
    /// MixedScriptTracker at all, so this only ever needs to evaluate the
    /// lowercase path a real user's lowercase keystrokes would hit) one
    /// letter at a time into a fresh session, and records the first
    /// prefix length at which the completion tooltip's top-1 prediction
    /// equals the token.
    private struct TokenOutcome {
        /// Prefix length at which top-1 first equalled the token, or nil
        /// if it never did (tried up to, but not including, the full
        /// token -- complete() only returns strictly-longer words, so the
        /// full-length prefix could never complete to itself anyway).
        let completableAtLetter: Int?
        let tokenLength: Int
        /// Whether Rule A ever locked the run as Latin at all. A token
        /// whose Bopomofo shape stays legal the whole way ("app" is
        /// `ㄇㄣ`, "coo" is `ㄏㄟ`) never becomes a Latin run, so no
        /// completion surface can fire for it -- no tooltip, no Tab, no
        /// window (docs/REVERIFY-P3-2026-09-12.md's P-4, where these were
        /// being counted as ranking misses and so as evidence that a
        /// better frequency source would help).
        ///
        /// Read off the composing buffer, which shows the raw ASCII run
        /// exactly when the tracker has locked it (see
        /// buildInputtingState's mixedScriptShowsLatinRun).
        let everLockedAsLatin: Bool
        /// True when Tab/Shift+Tab *would* have completed the token at a
        /// prefix too short for the tooltip to say so. Such a token is not
        /// a ranking failure -- the ranking found it, the display policy
        /// declined to volunteer it -- so it is counted separately rather
        /// than inflating "ranking miss".
        let completableOnlyBelowTheTooltipFloor: Bool
    }

    /// Mirrors KeyHandler's kMinLatinRunLengthForPredictionTooltip, which
    /// is a C++/ObjC file-static this test cannot import. Only used to
    /// decide where to bother probing the candidate window: above it the
    /// window and the tooltip ask the same question
    /// (_offeredCompletionFor:lexicon:) and cannot disagree.
    private static let tooltipRunLengthFloor = 4

    private func simulateCompletion(of token: String) -> TokenOutcome {
        let lower = token.lowercased()
        resetSession()
        var everLocked = false
        var completableBelowFloor = false
        for k in 1..<lower.count {
            let letter = String(lower[lower.index(lower.startIndex, offsetBy: k - 1)])
            type(letter)
            if composingBuffer == String(lower.prefix(k)) {
                everLocked = true
            }
            if let predicted = predictedCompletion, predicted.lowercased() == lower {
                return TokenOutcome(
                    completableAtLetter: k, tokenLength: lower.count,
                    everLockedAsLatin: true,
                    completableOnlyBelowTheTooltipFloor: false)
            }
            if k < Self.tooltipRunLengthFloor, !completableBelowFloor,
                offeredCompletion()?.lowercased() == lower
            {
                completableBelowFloor = true
            }
        }
        return TokenOutcome(
            completableAtLetter: nil, tokenLength: lower.count,
            everLockedAsLatin: everLocked,
            completableOnlyBelowTheTooltipFloor: completableBelowFloor)
    }

    /// P3 fix #4: eligible for LatinLexicon lookups the same way
    /// KeyHandler's _learnTypedLatinWordIfEligible: gates natural-typing
    /// learning (see Preferences.latinLearnTypedWords's doc) -- pure
    /// ASCII letters, length >= 3. Corpus English tokens are expected to
    /// already look like this, but a stray punctuation-attached token
    /// should not be miscategorized or fed to acceptLatinCompletion(value:).
    private func isEligibleLatinToken(_ token: String) -> Bool {
        token.count >= 3 && token.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// Coarse, deliberately simple suffix-stripping heuristic -- not a
    /// real lemmatizer -- used only to guess whether an inflected form
    /// missing from the dictionary might still have its lemma present
    /// (P3 fix #4's "inflected form" category). Static so
    /// UncompletableCategory.classify(_:lower:) below can call it without
    /// an instance.
    private static func plausibleLemmas(of lower: String) -> [String] {
        var candidates: [String] = []
        if lower.hasSuffix("ies"), lower.count > 4 {
            candidates.append(String(lower.dropLast(3)) + "y")
        }
        if lower.hasSuffix("es"), lower.count > 3 {
            candidates.append(String(lower.dropLast(2)))
        }
        if lower.hasSuffix("s"), lower.count > 2 {
            candidates.append(String(lower.dropLast(1)))
        }
        if lower.hasSuffix("ing"), lower.count > 4 {
            let stem = String(lower.dropLast(3))
            candidates.append(stem)
            candidates.append(stem + "e")
        }
        if lower.hasSuffix("ed"), lower.count > 3 {
            let stem = String(lower.dropLast(2))
            candidates.append(stem)
            candidates.append(stem + "e")
        }
        return candidates
    }

    /// Why a token was never completable. The order the tests below ask
    /// these questions in is the whole point (docs/REVIEW-P3-2026-09-11.md's
    /// N2): the dictionary is consulted *first*, and only a token the
    /// dictionary genuinely does not have is then judged on its casing.
    ///
    /// The previous order short-circuited on `hasUppercase`, so 61 of the
    /// 154 never-completable tokens -- `API`, `App`, `Apple`, `Blog`,
    /// `CLI`, `Games`, `Meet`, `Steam`, `Story`, `This`, `Tool`, ... --
    /// were filed as "proper noun / abbreviation" (i.e. "we would need a
    /// bigger word list") when their lowercase forms are ordinary
    /// dictionary entries that simply never won their prefix. The
    /// simulation types `lowercased()` anyway, so casing tells us nothing
    /// about whether the *lookup* could have succeeded.
    ///
    /// That distinction decides what P4 should do: a ranking miss is
    /// fixed by a real frequency source, a missing word by a bigger
    /// dictionary. They are not the same work.
    private enum UncompletableCategory {
        /// Rule A never locked this token as a Latin run, so no
        /// completion surface was ever reachable for it and the
        /// dictionary was never consulted. Asked *first*, ahead of every
        /// dictionary question, because a token in this class tells us
        /// nothing about the ranking data -- it is a P1 Rule-A coverage
        /// limit, and no frequency source can move it
        /// (docs/REVERIFY-P3-2026-09-12.md's P-4).
        case ruleANotTriggered
        /// Tab or Shift+Tab would have completed the token, but only at a
        /// prefix shorter than the tooltip's own floor, so the input
        /// method never said so. A display-policy cost, not a data
        /// problem: asked second, because counting these as ranking
        /// misses is the same mistake P-4 caught in a different place.
        case belowTooltipFloor
        /// The lowercase form *is* a recognized dictionary word, but no
        /// prefix of it ever ranked it as the top-1 completion -- a
        /// different, better-ranked word shares every tested prefix.
        case rankingMiss
        /// Not a dictionary word, but a plausible suffix-stripped lemma of
        /// it is -- an inflected form the dictionary is missing. P3 fix
        /// #1's SCOWL word list (which includes inflected forms directly,
        /// unlike the old web2-based one) should drive this toward 0.
        case inflectedForm
        /// Not a dictionary word and no lemma of it is either: a genuine
        /// vocabulary gap (a name, an acronym, a product).
        case notInDictionary

        /// `token` is the corpus form (case as written); `lower` is
        /// already lowercased (callers already have it, no need to
        /// recompute).
        static func classify(
            _ token: String, lower: String, outcome: TokenOutcome
        ) -> UncompletableCategory {
            if !outcome.everLockedAsLatin {
                return .ruleANotTriggered
            }
            if outcome.completableOnlyBelowTheTooltipFloor {
                return .belowTooltipFloor
            }
            if LanguageModelManager.isLatinWord(forTesting: lower) {
                return .rankingMiss
            }
            let lemmas = LatinCompletionKeyHandlerTests.plausibleLemmas(of: lower)
            if lemmas.contains(where: { LanguageModelManager.isLatinWord(forTesting: $0) }) {
                return .inflectedForm
            }
            return .notInDictionary
        }
    }

    private static let completableThresholds = [2, 3, 4, 5, 6]

    private struct EvalOutcome {
        var completableAtOrBelow: [Int: Int] =
            Dictionary(uniqueKeysWithValues: completableThresholds.map { ($0, 0) })
        var neverCompletable = 0
        var totalKeystrokesSaved = 0
        var total = 0
        var ruleANotTriggered = 0
        var belowTooltipFloor = 0
        var rankingMiss = 0
        var inflectedForm = 0
        var notInDictionary = 0
    }

    private func evaluate(_ token: String, into outcome: inout EvalOutcome) {
        outcome.total += 1
        let lower = token.lowercased()
        let result = simulateCompletion(of: token)
        if let k = result.completableAtLetter {
            for threshold in Self.completableThresholds where k <= threshold {
                outcome.completableAtOrBelow[threshold]! += 1
            }
            // The letters not typed, minus the one keystroke (Tab) spent
            // accepting the completion.
            outcome.totalKeystrokesSaved += max(0, result.tokenLength - k - 1)
        } else {
            outcome.neverCompletable += 1
            switch UncompletableCategory.classify(token, lower: lower, outcome: result) {
            case .ruleANotTriggered: outcome.ruleANotTriggered += 1
            case .belowTooltipFloor: outcome.belowTooltipFloor += 1
            case .rankingMiss: outcome.rankingMiss += 1
            case .inflectedForm: outcome.inflectedForm += 1
            case .notInDictionary: outcome.notInDictionary += 1
            }
        }
    }

    private func reportTable(_ outcome: EvalOutcome) -> String {
        let total = outcome.total
        func pct(_ n: Int) -> String {
            total == 0 ? "n/a" : String(format: "%.1f", Double(n) / Double(total) * 100)
        }
        let avgSaved = total == 0 ? 0 : Double(outcome.totalKeystrokesSaved) / Double(total)
        let rows = Self.completableThresholds.map { threshold in
            let n = outcome.completableAtOrBelow[threshold]!
            return "| completable within \(threshold) letters | \(n)/\(total) = \(pct(n))% |"
        }.joined(separator: "\n")
        return """
            | metric | value |
            |---|---|
            \(rows)
            | never completable | \(outcome.neverCompletable)/\(total) = \(pct(outcome.neverCompletable))% |
            | \u{2003}- Rule A never triggered (the run never became Latin at all) | \(outcome.ruleANotTriggered) |
            | \u{2003}- below the tooltip floor (Tab would have completed it, the tooltip never offered) | \(outcome.belowTooltipFloor) |
            | \u{2003}- ranking miss (in the dictionary, never ranked top-1 at any tested prefix) | \(outcome.rankingMiss) |
            | \u{2003}- inflected form (lemma in the dictionary, inflected form is not) | \(outcome.inflectedForm) |
            | \u{2003}- not in the dictionary (name, acronym, product) | \(outcome.notInDictionary) |
            | average keystrokes saved per token (letters skipped minus the Tab press, 0 for non-completable) | \(String(format: "%.2f", avgSaved)) |
            """
    }

    /// How many letters of an English token does the user actually have
    /// to type before Tab would complete it, on the corpus named by
    /// `BOPOMIX_EVAL_CORPUS` (a Traditional-Mandarin-plus-real-project-
    /// vocabulary TSV, kept outside this repo -- build one from your own
    /// text with tools/eval/build_corpus.py) -- measured two ways
    /// (P3 fix #4): "no history" evaluates
    /// every token cold, against just the built-in dictionary/tech seed;
    /// "with history" replays the corpus in row order, and after
    /// evaluating each row's tokens, types and commits every eligible one
    /// (see isEligibleLatinToken:) so the real learn-from-typing hook
    /// runs before moving to the next row -- so a word that recurs often
    /// enough to be confirmed becomes more completable later in the
    /// corpus. This is a measurement/report, not a
    /// correctness gate (except the pure-Chinese control below): skipped
    /// outright when `BOPOMIX_EVAL_CORPUS` is unset, and neither table
    /// asserts thresholds the way testEval200ThroughKeyHandler does --
    /// there is no prior baseline to hold either to yet, this run creates
    /// one for both.
    func testEval200LatinCompletion() throws {
        guard let corpusPath = ProcessInfo.processInfo.environment["BOPOMIX_EVAL_CORPUS"],
            !corpusPath.isEmpty
        else {
            throw XCTSkip(
                "BOPOMIX_EVAL_CORPUS is not set; nothing to measure. Point it at a "
                    + "corpus TSV built from your own text with tools/eval/build_corpus.py.")
        }
        guard FileManager.default.fileExists(atPath: corpusPath) else {
            throw XCTSkip(
                "BOPOMIX_EVAL_CORPUS points at \(corpusPath), which does not exist; "
                    + "nothing to measure. Build a corpus TSV from your own text with "
                    + "tools/eval/build_corpus.py.")
        }
        let rows = try loadEvalRows(at: corpusPath)
        XCTAssertFalse(rows.isEmpty)

        // --- No history: every token evaluated cold ---
        var noHistory = EvalOutcome()
        let allTokens = rows.flatMap { $0.englishTokens }.filter { $0.count >= 3 }
        XCTAssertFalse(allTokens.isEmpty)
        for token in allTokens {
            evaluate(token, into: &noHistory)
        }

        // --- With history: replay in corpus order, learning as we go ---
        // Reset first so this pass starts from the same clean dictionary
        // the "no history" pass did, rather than whatever residue (there
        // should be none, since evaluate() never accepts anything) the
        // pass above left behind.
        LanguageModelManager.resetLatinLexiconForTesting()
        LanguageModelManager.loadDataModels()
        try waitForLatinLexicon()
        var withHistory = EvalOutcome()
        for row in rows {
            let eligibleTokens = row.englishTokens.filter { $0.count >= 3 }
            for token in eligibleTokens {
                evaluate(token, into: &withHistory)
            }
            // Learning is replayed by *typing* the token and committing
            // it, which is the only thing production ever does
            // (KeyHandler's _commitMixedScriptLatinRun ->
            // _learnTypedLatinWordIfEligible). The previous version called
            // acceptLatinCompletion(value:) instead, which carries
            // kExplicitAcceptWeight and so confirmed every token on its
            // first occurrence -- an optimistic upper bound, not the
            // production rule the prose claimed
            // (docs/REVERIFY-P3-2026-09-12.md's P-4). Typing it also means
            // a token Rule A never locks is never learned here either,
            // exactly as on a real machine.
            for token in eligibleTokens where isEligibleLatinToken(token) {
                resetSession()
                type(token.lowercased() + " ")
            }
        }
        resetSession()

        // --- Pure-Chinese ON=OFF, character by character ---
        var zhMismatchedRows = 0
        var zhTotalChars = 0
        var zhMatchingChars = 0
        Preferences.latinCompletionEnabled = true
        for row in rows where !row.chineseOnlyKeys.isEmpty {
            resetSession()
            type(humanTypedKeys(row.chineseOnlyKeys))
            var enterPresses = 0
            while state is InputState.NotEmpty && enterPresses < 3 {
                pressEnter()
                enterPresses += 1
            }
            let on = committedText

            Preferences.latinCompletionEnabled = false
            resetSession()
            type(humanTypedKeys(row.chineseOnlyKeys))
            enterPresses = 0
            while state is InputState.NotEmpty && enterPresses < 3 {
                pressEnter()
                enterPresses += 1
            }
            let off = committedText
            Preferences.latinCompletionEnabled = true

            if on != off {
                zhMismatchedRows += 1
            }
            let onChars = Array(on)
            let offChars = Array(off)
            zhTotalChars += max(onChars.count, offChars.count)
            for i in 0..<min(onChars.count, offChars.count) where onChars[i] == offChars[i] {
                zhMatchingChars += 1
            }
        }

        let report = """

            ## P3 -- English prediction + Tab completion, \(Self.today())

            Produced by `LatinCompletionKeyHandlerTests.testEval200LatinCompletion`
            (`xcodebuild -scheme Bopomix test`). For every eval200 English
            token of length >= 3, simulates typing it letter by letter into
            a real `KeyHandler` and records the first prefix length at which
            the completion tooltip's top-1 prediction equals the token --
            i.e. how many letters the user would have typed before the
            input method offered the rest.

            This measures what the user is *shown*. Since P3 round 4 the
            tooltip needs a run of `kMinLatinRunLengthForPredictionTooltip`
            (4) letters before it appears, so the "within 2 letters" and
            "within 3 letters" rows below are necessarily 0 -- they are
            kept only so the table still lines up with the two earlier
            runs. Tab and Shift+Tab still complete a two-letter run on
            demand; what changed is that the input method no longer
            volunteers a guess that early. The reason is in
            docs/REVERIFY-P3-2026-09-12.md: over 100 keystrokes of 17
            words the reviewer types daily, the old floor of 2 put a wrong
            word on screen 33 times to save 7 keystrokes.

            Two passes: "no history" evaluates every token cold; "with
            history" replays the corpus in row order and, after evaluating
            each row, *types and commits* its eligible tokens, which is
            the only way production learns anything (KeyHandler's
            _commitMixedScriptLatinRun -> _learnTypedLatinWordIfEligible).
            Two commits of the same string are what confirm a word, so a
            token's third occurrence is the first that can benefit. Round
            3 instead called `acceptLatinCompletion(value:)`, which
            confirms a word in one call -- its 48.8% was an optimistic
            upper bound, not the production rule the prose claimed
            (docs/REVERIFY-P3-2026-09-12.md's P-4).

            "never completable" tokens are split by asking, in this order:
            **Rule A never triggered** (the letters never stopped being a
            legal Bopomofo shape, so the run never became Latin and no
            completion surface was reachable at all -- `app` is `ㄇㄣ`,
            `coo` is `ㄏㄟ`; a P1 coverage limit that no amount of
            frequency data can move), **below the tooltip floor** (pressing
            Tab or Shift+Tab at two or three letters *would* have completed
            the token; the ranking found it and the display policy declined
            to volunteer it), **ranking miss** (the lowercase form is a
            dictionary word that never ranked top-1 at any tested prefix --
            a different, better-ranked word owns every prefix),
            **inflected form** (a suffix-stripped lemma guess is a
            dictionary word but the exact form typed is not -- P3 fix #1's
            SCOWL-sourced word list, which includes inflected forms
            directly, keeps this near 0), and **not in the dictionary** (a
            genuine vocabulary gap: a name, an acronym, a product).

            Those first two categories are corrections. Round 2's
            version short-circuited on "does the token contain an
            uppercase letter", filing 61 tokens (`API`, `App`, `Apple`,
            `Blog`, `CLI`, `Games`, `Meet`, `Steam`, `Story`, `This`,
            `Tool`) as vocabulary gaps when their lowercase forms are
            ordinary dictionary entries; asking the dictionary first fixed
            that, but left a second error in place -- a token whose run
            never locked was counted as a ranking miss purely because its
            lowercase form is in the dictionary, which is how "62% of
            never-completable tokens are ranking misses" was arrived at.
            The tooltip floor would have created a third version of the
            same mistake, so it gets its own row too. Each points at
            different work: a ranking miss wants a real frequency source,
            a Rule-A failure wants better Rule-A coverage, a floor
            casualty wants a better way to surface a completion the
            ranking already has, and a missing word wants a bigger
            dictionary.

            What the two changes cost, stated plainly: average keystrokes
            saved per token went from 0.76 to \(String(format: "%.2f", Double(noHistory.totalKeystrokesSaved) / Double(max(noHistory.total, 1)))) with no history and from
            0.94 to \(String(format: "%.2f", Double(withHistory.totalKeystrokesSaved) / Double(max(withHistory.total, 1)))) with it. Roughly half of that is the tooltip
            floor (the "below the tooltip floor" row is the population that
            moved) and the rest is "with history" no longer confirming
            every token on its first sighting. Both are measurements of a
            deliberately more conservative product, not regressions to
            chase back.

            ### No history

            \(reportTable(noHistory))

            ### With history (production learning replayed between rows)

            \(reportTable(withHistory))

            ### Pure-Chinese control: ON vs OFF, character by character

            Same idea as testEval200ThroughKeyHandler's pure-Chinese control,
            but toggling `latinCompletionEnabled` (mixedScriptEnabled stays
            on in both runs) instead of `mixedScriptEnabled` itself, and only
            typing each row's Chinese-segment keys.

            | metric | value |
            |---|---|
            | rows with any character difference | \(zhMismatchedRows)/\(rows.filter { !$0.chineseOnlyKeys.isEmpty }.count) |
            | matching characters | \(zhMatchingChars)/\(zhTotalChars) = \(zhTotalChars == 0 ? "n/a" : String(format: "%.1f", Double(zhMatchingChars) / Double(zhTotalChars) * 100) + "%") |

            """

        print(report)

        // The only hard gate: completion must never touch pure-Chinese
        // output. Everything above it is descriptive, not a threshold --
        // there is no prior P3 number to hold this run to.
        XCTAssertEqual(zhMismatchedRows, 0, "latinCompletionEnabled must not change any pure-Chinese output")

        try writeBaselineSection(report)
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Replaces (or appends) the P3 section of `tools/eval/BASELINE.md` so
    /// re-running the suite refreshes it instead of stacking copies.
    /// Mirrors MixedScriptKeyHandlerTests.swift's writeBaselineSection,
    /// scoped to this file's own "## P3" marker so the two tests' sections
    /// coexist without clobbering each other regardless of run order.
    private func writeBaselineSection(_ report: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baseline = repoRoot.appendingPathComponent("tools/eval/BASELINE.md")
        guard FileManager.default.fileExists(atPath: baseline.path) else { return }
        let text = try String(contentsOf: baseline, encoding: .utf8)
        let marker = "\n## P3 -- English prediction"
        // Replaces only *this* section (up to, but not including, the
        // next top-level "## " heading, if any follow it), not everything
        // after the marker -- this and MixedScriptKeyHandlerTests.swift's
        // eval test both write BASELINE.md in the same suite and must not
        // clobber each other regardless of which runs second.
        let newText: String
        if let markerRange = text.range(of: marker) {
            let searchStart = text.index(after: markerRange.lowerBound)
            let sectionEnd =
                text.range(of: "\n## ", range: searchStart..<text.endIndex)?.lowerBound
                ?? text.endIndex
            newText = text.replacingCharacters(in: markerRange.lowerBound..<sectionEnd, with: report)
        } else {
            newText = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + report
        }
        try newText.write(to: baseline, atomically: true, encoding: .utf8)
    }
}
