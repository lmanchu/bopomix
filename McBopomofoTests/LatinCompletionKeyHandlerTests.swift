// Copyright (c) 2026 and onwards The Mixime Authors.
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

@testable import McBopomofo

/// KeyHandler-level integration tests for P3 English prediction + Tab
/// completion (see ~/.claude/plans/zhuyin-ime-personal.md's F3 scope).
/// Mirrors MixedScriptKeyHandlerTests' approach (drive the real KeyHandler
/// FSM, not the engine in isolation) for the same reason P1's review found:
/// every interesting interaction here is with candidate-window/Tab/grid
/// plumbing that the engine-level LatinLexicon/MixedScriptTracker tests
/// cannot see.
///
/// Word choice discipline: `LatinLexicon`'s built-in store and, more
/// importantly, its *user* store (`rememberWord`) are process-wide globals
/// that outlive any one test (see docs/REVERIFY-P1-2026-09-10.md's R12) --
/// an explicit Tab/candidate pick in *any* test file that runs in the same
/// process permanently promotes that word to the user's own lexicon (tier
/// 0), which would silently change another test's "top completion" if it
/// reused the same word. Every word this file picks anything for is
/// therefore either unique to this file or, for the Rule-B word, one of
/// the 15 dictionary-reachable ones (docs/REVERIFY-P1-2026-09-10.md's R10)
/// that MixedScriptKeyHandlerTests.swift does not already claim ("ell",
/// "full", "all"). Assertions about *which* word wins prefer dynamic
/// capture (read the tooltip/candidate list, then assert on what was
/// captured) over hard-coding a specific dictionary word, for the same
/// reason MixedScriptKeyHandlerTests' composingBufferAfterTypingFresh()
/// does: the ranking data (SCOWL tiers) is not something a test should be
/// pinned to.
class LatinCompletionKeyHandlerTests: XCTestCase {

    var handler = KeyHandler()

    private var savedKeyboardLayout: KeyboardLayout = .standard
    private var savedMixedScriptEnabled = false
    private var savedLatinCompletionEnabled = true
    private var savedLatinOnSpaceForUserWords = true
    private var savedAssociatedPhrasesEnabled = false
    private var savedChineseConversionEnabled = false
    private var savedEscToCleanInputBuffer = false
    private var savedKeepReadingUponCompositionError = false
    private var savedChooseCandidateUsingSpace = true
    private var savedCandidateKeys = "123456789"
    private var savedUseCustomUserPhraseLocation = false
    private var savedCustomUserPhraseLocation = ""
    private var temporaryUserDataFolder: URL?

    // Rolling state for the typing helpers below.
    private var state: InputState = InputState.Empty()
    private var committedText = ""
    private var errorCount = 0

    override func setUpWithError() throws {
        savedKeyboardLayout = Preferences.keyboardLayout
        savedMixedScriptEnabled = Preferences.mixedScriptEnabled
        savedLatinCompletionEnabled = Preferences.latinCompletionEnabled
        savedLatinOnSpaceForUserWords = Preferences.mixedScriptLatinOnSpaceForUserWords
        savedAssociatedPhrasesEnabled = Preferences.associatedPhrasesEnabled
        savedChineseConversionEnabled = Preferences.chineseConversionEnabled
        savedEscToCleanInputBuffer = Preferences.escToCleanInputBuffer
        savedKeepReadingUponCompositionError = Preferences.keepReadingUponCompositionError
        savedChooseCandidateUsingSpace = Preferences.chooseCandidateUsingSpace
        savedCandidateKeys = Preferences.candidateKeys
        savedUseCustomUserPhraseLocation = Preferences.useCustomUserPhraseLocation
        savedCustomUserPhraseLocation = Preferences.customUserPhraseLocation

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
        // never in the real one on this machine.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixime-completion-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        temporaryUserDataFolder = folder
        Preferences.useCustomUserPhraseLocation = true
        Preferences.customUserPhraseLocation = folder.path

        LanguageModelManager.loadDataModels()
        try waitForLatinLexicon()

        handler = KeyHandler()
        handler.inputMode = .bopomofo
        resetSession()
    }

    override func tearDownWithError() throws {
        Preferences.keyboardLayout = savedKeyboardLayout
        Preferences.mixedScriptEnabled = savedMixedScriptEnabled
        Preferences.latinCompletionEnabled = savedLatinCompletionEnabled
        Preferences.mixedScriptLatinOnSpaceForUserWords = savedLatinOnSpaceForUserWords
        Preferences.associatedPhrasesEnabled = savedAssociatedPhrasesEnabled
        Preferences.chineseConversionEnabled = savedChineseConversionEnabled
        Preferences.escToCleanInputBuffer = savedEscToCleanInputBuffer
        Preferences.keepReadingUponCompositionError = savedKeepReadingUponCompositionError
        Preferences.chooseCandidateUsingSpace = savedChooseCandidateUsingSpace
        Preferences.candidateKeys = savedCandidateKeys
        Preferences.useCustomUserPhraseLocation = savedUseCustomUserPhraseLocation
        Preferences.customUserPhraseLocation = savedCustomUserPhraseLocation

        if let folder = temporaryUserDataFolder {
            try? FileManager.default.removeItem(at: folder)
            temporaryUserDataFolder = nil
        }
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

    private func pressShiftTab() {
        send(" ", charCode: 0, keyCode: KeyCode.tab.rawValue, flags: .shift)
    }

    private var composingBuffer: String {
        (state as? InputState.NotEmpty)?.composingBuffer ?? ""
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

    /// "th" locks by the 2nd letter and the dictionary has hundreds of
    /// longer words starting with it, so a prediction must appear.
    func testTooltipShowsALongerCompletionOnceLocked() {
        type("th")
        XCTAssertEqual(composingBuffer, "th")
        guard let predicted = predictedCompletion else {
            XCTFail("expected a completion tooltip, got: \(state)")
            return
        }
        XCTAssertTrue(predicted.hasPrefix("th"), predicted)
        XCTAssertGreaterThan(predicted.count, 2, predicted)
    }

    /// Turning the preference off must remove the tooltip even though
    /// mixedScript itself (and so Rule A locking) is still on.
    func testNoTooltipWhenLatinCompletionDisabled() {
        Preferences.latinCompletionEnabled = false
        type("th")
        XCTAssertEqual(composingBuffer, "th")
        XCTAssertNil(predictedCompletion, "\(state)")
    }

    // MARK: - Tab accepts the top completion and typing continues

    func testTabAcceptsTopCompletionAndContinuesTyping() {
        type("th")
        guard let predicted = predictedCompletion else {
            XCTFail("expected a completion tooltip, got: \(state)")
            return
        }
        pressTab()
        XCTAssertEqual(composingBuffer, predicted)
        XCTAssertNil(predictedCompletion, "no completion is longer than itself: \(state)")

        // Typing on extends the *completed* word, not the original "th".
        type("s")
        XCTAssertEqual(composingBuffer, predicted + "s")
    }

    /// Backspacing after an accepted completion shortens the completed
    /// word, matching MixedScriptTracker's PopLastLatinCharAfterAcceptingCompletion.
    func testBackspaceAfterAcceptingCompletionShortensTheCompletedWord() {
        type("th")
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
    /// docs/REVERIFY-P1-2026-09-10.md's R10) not already claimed by
    /// MixedScriptKeyHandlerTests.swift ("ell"/"full"/"all"). Its shape
    /// stays alive the whole time (rule B, not rule A), so the *first*
    /// Tab press must still do exactly what P1 always did -- flip to the
    /// English form -- and only a *second* Tab press (this node now
    /// showing plain ASCII) should look for a completion.
    func testRuleBFlipThenTabCompletesFurther() {
        type("coo ")
        XCTAssertEqual(composingBuffer, "黑")
        pressTab()
        XCTAssertEqual(composingBuffer, "coo", "P1's existing Tab-flips-to-English behavior must be unchanged")

        pressTab()
        XCTAssertGreaterThan(composingBuffer.count, 3, "\(state)")
        XCTAssertTrue(composingBuffer.hasPrefix("coo"), composingBuffer)
    }

    /// A different Rule-B word from testRuleBFlipThenTabCompletesFurther's
    /// "coo" on purpose (see this file's word-choice discipline note at
    /// the top): that test's first Tab press teaches "coo" into the
    /// process-wide user lexicon (fixNodeWithReading: learns any actual
    /// mixedScript pick), which would make a *later* "coo " in this test
    /// auto-commit as English immediately (onBoundary()) rather than
    /// showing the Chinese default this test wants to start from. "zoo"
    /// (also one of the 15) is avoided too: its key sequence shares
    /// MixedScriptKeyHandlerTests.swift's "zo " tone-1-syllable reading
    /// (see testB1_ToneOneSyllablesThatAreAlsoEnglishWordsStayChinese),
    /// so cycling/observing a candidate for it here would leak a
    /// UserOverrideModel preference into that unrelated test -- found by
    /// running the full suite, not by inspection. "ssl" shares no prefix
    /// with any syllable another test in this repo already exercises.
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
        type("th")
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
        type("th")
        XCTAssertNotEqual(
            predictedCompletion, chosenWord,
            "test setup: pick a candidate that was not already on top")

        handler.acceptLatinCompletion(value: chosenWord)

        resetSession()
        type("th")
        XCTAssertEqual(predictedCompletion, chosenWord)
    }

    /// Accepting the same word twice bumps its count rather than just
    /// re-recording membership -- verified indirectly (LatinLexiconTest's
    /// RememberWordCountsRepeatedAcceptances/RememberWordRewritesExistingCountInPlace
    /// cover the counting mechanics directly): this only pins that
    /// KeyHandler's accept path is idempotent-safe to call twice in a row
    /// and the word stays the top choice.
    func testAcceptingTheSameCompletionTwiceStaysConsistent() {
        type("th")
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
        type("th")
        XCTAssertEqual(predictedCompletion, chosenWord)
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

    /// How many letters of an English token does the user actually have
    /// to type before Tab would complete it, and how does that change
    /// with completion on vs off, on eval200 (the only Traditional-
    /// Mandarin-plus-real-project-vocabulary corpus this repo has). This
    /// is a measurement/report, not a correctness gate: skipped outright
    /// when the private corpus is not present, and it does not assert
    /// thresholds the way testEval200ThroughKeyHandler does (there is no
    /// prior baseline to hold this to yet -- this run creates one).
    ///
    /// Caveat this test accepts rather than engineers around: LatinLexicon
    /// is a process-wide global (docs/REVERIFY-P1-2026-09-10.md's R12),
    /// so if XCTest happens to run this file's other tests first (it
    /// currently does -- they sort before "E" alphabetically), a handful
    /// of eval200 tokens that happen to share a prefix with a word one of
    /// those tests explicitly accepted ("throughput" et al for "th") measure
    /// as artificially more completable than a fresh install would see.
    /// Acceptable for an aggregate statistic over hundreds of tokens; would
    /// not be for a single hard-coded assertion.
    func testEval200LatinCompletion() throws {
        let corpusPath = NSHomeDirectory() + "/Dev/mixime-private/eval200.tsv"
        guard FileManager.default.fileExists(atPath: corpusPath) else {
            throw XCTSkip("corpus not present at \(corpusPath); nothing to measure")
        }
        let rows = try loadEvalRows(at: corpusPath)
        XCTAssertFalse(rows.isEmpty)

        let tokens = rows.flatMap { $0.englishTokens }.filter { $0.count >= 3 }
        XCTAssertFalse(tokens.isEmpty)

        var completableAtOrBelow: [Int: Int] = [2: 0, 3: 0, 4: 0]
        var neverCompletable = 0
        var totalKeystrokesSaved = 0

        for token in tokens {
            let lower = token.lowercased()
            resetSession()
            var foundAtK: Int?
            for k in 1..<lower.count {
                let letter = String(lower[lower.index(lower.startIndex, offsetBy: k - 1)])
                type(letter)
                if let predicted = predictedCompletion, predicted.lowercased() == lower {
                    foundAtK = k
                    break
                }
            }
            if let k = foundAtK {
                for threshold in [2, 3, 4] where k <= threshold {
                    completableAtOrBelow[threshold]! += 1
                }
                // The letters not typed, minus the one keystroke (Tab)
                // spent accepting the completion.
                totalKeystrokesSaved += max(0, lower.count - k - 1)
            } else {
                neverCompletable += 1
            }
        }

        let total = tokens.count
        func pct(_ n: Int) -> String {
            String(format: "%.1f", Double(n) / Double(total) * 100)
        }
        let avgSaved = Double(totalKeystrokesSaved) / Double(total)

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
            (`xcodebuild -scheme McBopomofo test`). For every eval200 English
            token of length >= 3 (\(total) of them), simulates typing it letter
            by letter into a real `KeyHandler` and records the first prefix
            length at which the completion tooltip's top-1 prediction equals
            the token -- i.e. how many letters the user would actually have
            typed before Tab completes it. See this test's doc comment for
            the one caveat on cross-test lexicon state this number carries.

            | metric | value |
            |---|---|
            | completable within 2 letters | \(completableAtOrBelow[2]!)/\(total) = \(pct(completableAtOrBelow[2]!))% |
            | completable within 3 letters | \(completableAtOrBelow[3]!)/\(total) = \(pct(completableAtOrBelow[3]!))% |
            | completable within 4 letters | \(completableAtOrBelow[4]!)/\(total) = \(pct(completableAtOrBelow[4]!))% |
            | never completable (no dictionary match at any prefix) | \(neverCompletable)/\(total) = \(pct(neverCompletable))% |
            | average keystrokes saved per token (letters skipped minus the Tab press, 0 for non-completable) | \(String(format: "%.2f", avgSaved)) |

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
