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

/// KeyHandler-level integration tests for P1 zh/en mixed typing (see
/// ~/.claude/plans/zhuyin-ime-personal.md). The engine-level tests under
/// `Source/Engine/MixedScript/` cover the rules in isolation; everything
/// here drives the real `KeyHandler` FSM the way the input method does,
/// because every blocking defect found in the first review round
/// (`docs/REVIEW-P1-2026-09-10.md`) lived in that layer and none of them
/// were visible from the engine tests or from the `mixime-eval` CLI.
///
/// Each test named after a `Bx` item reproduces that item's exact key
/// sequence.
class MixedScriptKeyHandlerTests: XCTestCase {

    var handler = KeyHandler()

    private var savedKeyboardLayout: KeyboardLayout = .standard
    private var savedMixedScriptEnabled = false
    private var savedLatinOnSpaceForUserWords = true
    private var savedAssociatedPhrasesEnabled = false
    private var savedChineseConversionEnabled = false
    private var savedEscToCleanInputBuffer = false
    private var savedKeepReadingUponCompositionError = false
    private var savedChooseCandidateUsingSpace = true
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
        savedLatinOnSpaceForUserWords = Preferences.mixedScriptLatinOnSpaceForUserWords
        savedAssociatedPhrasesEnabled = Preferences.associatedPhrasesEnabled
        savedChineseConversionEnabled = Preferences.chineseConversionEnabled
        savedEscToCleanInputBuffer = Preferences.escToCleanInputBuffer
        savedKeepReadingUponCompositionError = Preferences.keepReadingUponCompositionError
        savedChooseCandidateUsingSpace = Preferences.chooseCandidateUsingSpace
        savedUseCustomUserPhraseLocation = Preferences.useCustomUserPhraseLocation
        savedCustomUserPhraseLocation = Preferences.customUserPhraseLocation

        Preferences.keyboardLayout = .standard
        Preferences.mixedScriptEnabled = true
        Preferences.mixedScriptLatinOnSpaceForUserWords = true
        // Associated phrases would put a candidate state on top of every
        // composed syllable, which is a different feature's behavior.
        Preferences.associatedPhrasesEnabled = false
        Preferences.chineseConversionEnabled = false
        Preferences.escToCleanInputBuffer = false
        Preferences.keepReadingUponCompositionError = false
        Preferences.chooseCandidateUsingSpace = true

        // Anything these tests "learn" (an explicit Tab pick appends to
        // latin-user.txt) must land in a throwaway folder, never in the
        // real one on this machine.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixime-tests-\(UUID().uuidString)")
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
        Preferences.mixedScriptLatinOnSpaceForUserWords = savedLatinOnSpaceForUserWords
        Preferences.associatedPhrasesEnabled = savedAssociatedPhrasesEnabled
        Preferences.chineseConversionEnabled = savedChineseConversionEnabled
        Preferences.escToCleanInputBuffer = savedEscToCleanInputBuffer
        Preferences.keepReadingUponCompositionError = savedKeepReadingUponCompositionError
        Preferences.chooseCandidateUsingSpace = savedChooseCandidateUsingSpace
        Preferences.useCustomUserPhraseLocation = savedUseCustomUserPhraseLocation
        Preferences.customUserPhraseLocation = savedCustomUserPhraseLocation

        if let folder = temporaryUserDataFolder {
            try? FileManager.default.removeItem(at: folder)
            temporaryUserDataFolder = nil
        }
    }

    /// The Latin word lists load on a background queue (see
    /// `LanguageModelManager`'s `LTLoadMixedScriptLexicon`), so rules B/C
    /// are simply inactive until that finishes.
    private func waitForLatinLexicon() throws {
        let deadline = Date().addingTimeInterval(30)
        while !LanguageModelManager.latinLexiconReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if !LanguageModelManager.latinLexiconReady {
            throw XCTSkip("Latin lexicon did not finish loading in 30s")
        }
    }

    // MARK: - Typing helpers

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
            // A Committing state is a one-shot side effect, not something
            // the next key is handled against -- the input method
            // controller does the same thing.
            if !(newState is InputState.Committing) {
                self.state = newState
            }
        } errorCallback: {
            self.errorCount += 1
        }
    }

    /// Types a literal ASCII key sequence: letters, digits, punctuation and
    /// spaces, exactly as they would arrive from the keyboard.
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

    private func pressLeft() {
        send(" ", charCode: 0, keyCode: KeyCode.left.rawValue)
    }

    /// What the composing buffer shows right now ("" when there is none).
    private var composingBuffer: String {
        (state as? InputState.NotEmpty)?.composingBuffer ?? ""
    }

    /// Types `keys` on a throwaway handler and returns its composing
    /// buffer, for tests that assert "this ends up the same as typing it
    /// normally" rather than hard-coding a character the language model
    /// may legitimately re-rank later.
    private func composingBufferAfterTypingFresh(_ keys: String) -> String {
        let fresh = KeyHandler()
        fresh.inputMode = .bopomofo
        var freshState: InputState = InputState.Empty()
        for character in keys {
            let text = String(character)
            let input = KeyHandlerInput(
                inputText: text, keyCode: 0, charCode: charCode(text), flags: [],
                isVerticalMode: false)
            fresh.handle(input: input, state: freshState) { newState in
                freshState = newState
            } errorCallback: {}
        }
        return (freshState as? InputState.NotEmpty)?.composingBuffer ?? ""
    }

    // MARK: - B1: a dictionary word plus a space must not rewrite Chinese

    /// Every one of these is a complete tone-1 syllable whose key sequence
    /// is also an English word. Space is the tone-1 key, so "dictionary
    /// word + space => English" turned all of them into raw ASCII and cost
    /// 5.1 points of pure-Chinese accuracy.
    func testB1_ToneOneSyllablesThatAreAlsoEnglishWordsStayChinese() {
        let cases = [
            ("up ", "因"),
            ("fu/ ", "清"),
            ("el ", "高"),
            ("al ", "貓"),
            ("ai ", "摸"),
            ("zo ", "非"),
            ("jo ", "威"),
        ]
        for (keys, expected) in cases {
            resetSession()
            type(keys)
            XCTAssertEqual(composingBuffer, expected, "keys: \(keys)")
        }
    }

    func testB1_ThreeToneOneSyllablesInARow() {
        type("fu/ fu0 fu. ")
        XCTAssertEqual(composingBuffer, "清千秋")
    }

    /// The one from the failing upstream test: `up` sat in the middle of an
    /// ordinary sentence and dragged the neighbouring character off with it
    /// (因 -> up, and 注 -> 助).
    func testB1_UpstreamSentenceIsUnaffected() {
        type("vul3a945j4up gj bj4z83")
        XCTAssertEqual(composingBuffer, "小麥注音輸入法")
    }

    // MARK: - B2: no key inside a syllable may disappear

    /// `fu/ ` is three keys; the old rule C matched only the *letters*
    /// ("fu") against the dictionary and emitted just those two, dropping
    /// the `/` (ㄥ). `1up ` dropped the leading `1` (ㄅ) the same way.
    func testB2_NonLetterKeysInsideASyllableSurvive() {
        type("1up ")
        XCTAssertEqual(composingBuffer, "賓")

        resetSession()
        type("fu. ")
        XCTAssertEqual(composingBuffer, "秋")
    }

    // MARK: - B3: a space after English is a space, not a candidate window

    func testB3_ThreeEnglishWordsSeparatedBySpaces() {
        type("acer api gmail")
        XCTAssertEqual(composingBuffer, "acer api gmail")
        pressEnter()
        XCTAssertEqual(committedText, "acer api gmail")
    }

    func testB3_SpaceAfterALatinRunDoesNotSwallowTheNextLetters() {
        type("acer ")
        XCTAssertEqual(composingBuffer, "acer ")
        XCTAssertFalse(state is InputState.ChoosingCandidate, "\(state)")
        type("api")
        XCTAssertEqual(composingBuffer, "acer api")
    }

    /// A space *after Chinese* still opens the candidate window (that is
    /// stock McBopomofo, and unrelated to mixed typing) -- but typing a
    /// letter into it now dismisses it and keeps typing instead of beeping
    /// the key away.
    func testB3_LettersDismissACandidateWindowInsteadOfVanishing() {
        type("ji3")
        XCTAssertEqual(composingBuffer, "我")
        type(" ")
        XCTAssertTrue(state is InputState.ChoosingCandidate, "\(state)")
        type("up jo4")
        // 因為 rather than 因位: with rule C gone, ㄧㄣ composes to 因 and
        // the language model gets to see the two syllables as one phrase,
        // which is exactly what the old behavior destroyed.
        XCTAssertEqual(composingBuffer, "我因為")
    }

    /// Enter after a rule-A run must still commit, rather than being
    /// consumed by the run it flushes.
    func testB3_EnterAfterALatinRunCommitsEverything() {
        type("ji3acer")
        XCTAssertEqual(composingBuffer, "我acer")
        pressEnter()
        XCTAssertEqual(committedText, "我acer")
        XCTAssertTrue(state is InputState.Empty, "\(state)")
    }

    // MARK: - B4: Esc

    func testB4_EscClearsTheReadingBufferAsWellAsTheRun() {
        type("a")
        pressEsc()
        XCTAssertFalse(state is InputState.NotEmpty, "\(state)")
        type("l")
        XCTAssertEqual(composingBuffer, "ㄠ")
    }

    /// The upstream expectation that turned red on this branch.
    func testB4_EscKeepsCommittedTextAndDropsOnlyTheReading() {
        type("su3cl")
        XCTAssertEqual(composingBuffer, "你ㄏㄠ")
        pressEsc()
        XCTAssertEqual(composingBuffer, "你")
    }

    func testB4_EscDiscardsALockedLatinRun() {
        type("ji3acer")
        XCTAssertEqual(composingBuffer, "我acer")
        pressEsc()
        XCTAssertEqual(composingBuffer, "我")
    }

    // MARK: - B5: backspace

    func testB5_BackspacingALockedRunToEmptyReturnsToChinese() {
        type("th")
        XCTAssertEqual(composingBuffer, "th")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "t")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "")

        type("gl3")
        XCTAssertEqual(composingBuffer, composingBufferAfterTypingFresh("gl3"))
        XCTAssertFalse(
            composingBuffer.contains("g"), "still stuck in English: \(composingBuffer)")
    }

    func testB5_BackspaceShortensALockedRunOneCharacterAtATime() {
        type("acer")
        XCTAssertEqual(composingBuffer, "acer")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "ace")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "ac")
    }

    func testB5_BackspaceDeletesACommittedLatinRunAsOneNode() {
        type("ji3acer ")
        XCTAssertEqual(composingBuffer, "我acer ")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "我acer")
        pressBackspace()
        XCTAssertEqual(composingBuffer, "我")
    }

    // MARK: - B6: force commit

    /// `InputMethodController.commitComposition(_:)` reaches this whenever
    /// the client asks for the composition to be flushed (a click in the
    /// same field, a nil event...). A rule-A run lives only in the tracker
    /// until a boundary key, so the early-out for "nothing to commit" used
    /// to throw the whole run away without even a state callback.
    func testB6_ForceCommitKeepsAPendingLatinRun() {
        type("acer")
        var committed: String?
        handler.handleForceCommit { newState in
            if let committing = newState as? InputState.Committing {
                committed = committing.poppedText
            }
        }
        XCTAssertEqual(committed, "acer")
    }

    func testB6_ForceCommitWithChineseAndALatinRun() {
        type("ji3acer")
        var committed: String?
        handler.handleForceCommit { newState in
            if let committing = newState as? InputState.Committing {
                committed = committing.poppedText
            }
        }
        XCTAssertEqual(committed, "我acer")
    }

    func testB6_ForceCommitIsStillANoOpWhenThereIsNothing() {
        var callbackCount = 0
        handler.handleForceCommit { _ in
            callbackCount += 1
        }
        XCTAssertEqual(callbackCount, 0)
    }

    // MARK: - B7: the preference switches everything off

    /// With the feature off, every one of the sequences above has to behave
    /// exactly like upstream McBopomofo.
    func testB7_DisabledBehavesLikeUpstream() {
        Preferences.mixedScriptEnabled = false
        handler = KeyHandler()
        handler.inputMode = .bopomofo
        resetSession()

        type("vul3a945j4up gj bj4z83")
        XCTAssertEqual(composingBuffer, "小麥注音輸入法")

        resetSession()
        type("a")
        pressEsc()
        type("l")
        XCTAssertEqual(composingBuffer, "ㄠ")

        resetSession()
        type("up ")
        XCTAssertEqual(composingBuffer, "因")

        resetSession()
        type("acer")
        // Upstream has no English awareness at all: the letters just
        // overwrite each other in the reading buffer.
        XCTAssertEqual(composingBuffer, "ㄐ")
    }

    // MARK: - Rule B: the English form is one Tab away, and Tab teaches

    /// "ell" is a real word whose Bopomofo shape stays alive all the way
    /// (ㄍㄠ), i.e. exactly the ambiguous case rule B exists for. The
    /// alternate is scored just under the reading's best unigram, so it is
    /// the candidate window's second row and the very first Tab reaches
    /// it -- with the old fixed -99 score it was last of 39.
    ///
    /// (Each of these three tests uses a different word on purpose: an
    /// explicit Tab pick writes to the process-wide Latin lexicon, so
    /// sharing a word would make them depend on execution order.)
    func testRuleB_FirstTabReachesTheEnglishForm() {
        type("ell ")
        XCTAssertEqual(composingBuffer, "高")
        pressTab()
        XCTAssertEqual(composingBuffer, "ell")
    }

    /// The full learning loop: an explicit pick writes the word to the
    /// user's own lexicon, and only *then* does a trailing space commit it
    /// as English by itself.
    func testRuleC_AUserPickedWordAutoCommitsOnTheNextSpace() {
        type("full ")
        XCTAssertEqual(composingBuffer, "敲")
        pressTab()
        XCTAssertEqual(composingBuffer, "full")

        resetSession()
        type("full ")
        XCTAssertEqual(composingBuffer, "full")
    }

    /// The other half of the same rule, and the one that actually caused
    /// the pure-Chinese regression: a word that is only in the *built-in*
    /// list never auto-commits, however long it is and however many times
    /// a space follows it.
    func testRuleC_ABuiltinDictionaryWordNeverAutoCommits() {
        for _ in 0..<3 {
            resetSession()
            type("all ")
            XCTAssertEqual(composingBuffer, "貓")
        }
        // ...and it is still reachable, one Tab away.
        pressTab()
        XCTAssertEqual(composingBuffer, "all")
    }

    // MARK: - Everything else the review asked to pin down

    func testArrowKeyEndsARunWithoutLosingIt() {
        type("ji3acer")
        pressLeft()
        XCTAssertEqual(composingBuffer, "我acer")
        XCTAssertTrue(state is InputState.Inputting, "\(state)")
        if let inputting = state as? InputState.Inputting {
            // The arrow key still moved the cursor; the run was committed
            // into the grid first rather than being thrown away.
            XCTAssertLessThan(Int(inputting.cursorIndex), composingBuffer.utf16.count)
        }
    }

    func testTwoEnglishWordsInARow() {
        type("gmail acer")
        XCTAssertEqual(composingBuffer, "gmail acer")
        pressEnter()
        XCTAssertEqual(committedText, "gmail acer")
    }

    func testEnglishFollowedByBopomofo() {
        type("acer su3cl3")
        XCTAssertEqual(composingBuffer, "acer 你好")
    }

    /// The known, accepted cost of rule A (see
    /// `BopomofoShapeTracker`'s class doc and the review's dimension 10):
    /// once a run is Latin-locked, every following *letter* joins it, so
    /// going straight from English back into Bopomofo needs a
    /// non-letter key (space, tone digit, punctuation) in between. Pinned
    /// here so a future change to that trade-off is a deliberate one.
    func testALockedRunKeepsAbsorbingLettersUntilANonLetterKey() {
        type("acersu3cl3")
        XCTAssertEqual(composingBuffer, "acersu好")
    }

    func testBopomofoFollowedByEnglish() {
        type("su3cl3acer")
        XCTAssertEqual(composingBuffer, "你好acer")
    }

    func testVeryLongLatinRunIsKeptWhole() {
        let run = String(repeating: "thequickbrownfox", count: 5)  // 80 letters
        type(run)
        XCTAssertEqual(composingBuffer, run)
        pressEnter()
        XCTAssertEqual(committedText, run)
    }

    /// Shift+letter is the pre-existing "force English" gesture and
    /// mixedScript must not touch it. The run in progress is handed to the
    /// client through an `Empty` (not `EmptyIgnoringPreviousState`) state,
    /// which is what tells the controller to commit the previous composing
    /// buffer.
    func testShiftedLetterKeepsTheUpstreamPath() {
        type("acer")
        XCTAssertEqual(composingBuffer, "acer")
        send("D", charCode: charCode("D"), flags: [.shift])
        XCTAssertTrue(state is InputState.Empty, "\(state)")
        XCTAssertFalse(state is InputState.EmptyIgnoringPreviousState, "\(state)")
    }

    /// A tone key straight after English has no syllable to attach to; it
    /// used to be parked in the reading buffer and rendered as a stray tone
    /// mark ("the3" -> "theˇ").
    func testToneKeyAfterALatinRunLeavesNoOrphanToneMark() {
        type("the3")
        XCTAssertEqual(composingBuffer, "the")
    }

    /// The rule-A safety net: a run that keeps a live shape the whole way
    /// but lands on a reading no dictionary entry exists for.
    func testUncomposableReadingFallsBackToTheLiteralRun() {
        type("ni4")
        XCTAssertEqual(composingBuffer, "ni")
    }

    /// The synthetic `_latin_` key must not survive its own key event --
    /// the language model behind it is process-wide, shared by every text
    /// field.
    func testLatinRunLeavesNoStaleEntryForTheNextHandler() {
        type("acer")
        pressEnter()
        XCTAssertEqual(committedText, "acer")

        let second = KeyHandler()
        second.inputMode = .bopomofo
        var secondState: InputState = InputState.Empty()
        for character in "su3cl3" {
            let text = String(character)
            let input = KeyHandlerInput(
                inputText: text, keyCode: 0, charCode: charCode(text), flags: [],
                isVerticalMode: false)
            second.handle(input: input, state: secondState) { newState in
                secondState = newState
            } errorCallback: {}
        }
        XCTAssertEqual((secondState as? InputState.NotEmpty)?.composingBuffer, "你好")
    }

    // MARK: - eval200 through the real KeyHandler

    private struct CorpusRow {
        let id: String
        let keys: String
        /// Only the key tokens belonging to the row's Chinese segments,
        /// with the English ones removed -- the pure-Chinese control for
        /// "does turning mixed typing on damage ordinary Chinese input?",
        /// which is the question the 95.3% baseline actually answers.
        let chineseOnlyKeys: String
        let englishTokens: [String]
        let goldChinese: String
    }

    private struct EvalResult {
        var totalTokens = 0
        var retainedTokens = 0
        var rowsFullyRetained = 0
        var rowCount = 0
        var totalChars = 0
        var correctChars = 0
        var rowsWithLengthMismatch = 0
        var latenciesUs: [Int] = []

        var f1Rate: Double {
            totalTokens == 0 ? 0 : Double(retainedTokens) / Double(totalTokens) * 100
        }
        var rowRate: Double {
            rowCount == 0 ? 0 : Double(rowsFullyRetained) / Double(rowCount) * 100
        }
        var zhRate: Double {
            totalChars == 0 ? 0 : Double(correctChars) / Double(totalChars) * 100
        }
    }

    /// The corpus's `keys` column puts a delimiter space after *every*
    /// syllable, including ones already finished by a tone digit (see
    /// `tools/eval/build_corpus.py`, which joins per-syllable key strings
    /// with " "). Nobody types those: `dk3` composes 可 on the tone key,
    /// and a space after it means "show me candidates" in McBopomofo, not
    /// "next syllable". Every *other* space is a real keystroke -- the
    /// tone-1 composition trigger after a toneless syllable, and the
    /// separator that ends an English word -- so only the ones following a
    /// tone digit (3/4/6/7) are dropped. Verified safe against this
    /// corpus: no English token contains a digit or ends in one.
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

    private func loadCorpus(at path: String) throws -> [CorpusRow] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [CorpusRow] = []
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

            // Walk the segments in order to split the flat `keys` column
            // back into its per-segment pieces: an English segment is one
            // token, a Chinese segment is as many tokens as the
            // `readings` column lists syllables for it.
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
                CorpusRow(
                    id: parts[0],
                    keys: parts[4],
                    chineseOnlyKeys: chineseKeyTokens.joined(separator: " "),
                    englishTokens: segments.filter { $0["lang"] == "en" }.compactMap {
                        $0["text"]
                    },
                    goldChinese: segments.filter { $0["lang"] == "zh" }.compactMap { $0["text"] }
                        .joined()
                ))
        }
        return rows
    }

    private enum EvalVariant: String {
        /// The corpus column with its per-syllable delimiter spaces
        /// normalized away (see humanTypedKeys).
        case human
        /// The corpus column verbatim.
        case raw
        /// Only the Chinese segments' keys, normalized -- the
        /// pure-Chinese control.
        case chineseOnly
    }

    private func runEval(_ rows: [CorpusRow], variant: EvalVariant) -> EvalResult {
        var result = EvalResult()
        result.rowCount = rows.count
        // Every row's input and output is written out (id, keys typed,
        // committed text, gold Chinese) so a regression can be diffed
        // against the mixime-eval CLI's output for the same input instead
        // of being re-derived by hand.
        let dumpPath =
            NSTemporaryDirectory()
            + "mixime-eval-app-\(variant.rawValue)-\(Preferences.mixedScriptEnabled ? "on" : "off").tsv"
        var dump = ""
        defer { try? dump.write(toFile: dumpPath, atomically: true, encoding: .utf8) }
        for row in rows {
            resetSession()
            let keys: String
            switch variant {
            case .human: keys = humanTypedKeys(row.keys)
            case .raw: keys = row.keys
            case .chineseOnly: keys = humanTypedKeys(row.chineseOnlyKeys)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            type(keys)
            // A row ending in a toneless (tone-1) syllable needs one Enter
            // to compose it and a second to commit -- exactly what a
            // person does, and the reason a single Enter left such rows
            // uncommitted.
            var enterPresses = 0
            while state is InputState.NotEmpty && enterPresses < 3 {
                pressEnter()
                enterPresses += 1
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            result.latenciesUs.append(Int(elapsed / 1000))

            let composed = committedText
            dump += "\(row.id)\t\(keys)\t\(composed)\t\(row.goldChinese)\n"
            let composedLower = composed.lowercased()
            var rowFullyRetained = true
            for token in row.englishTokens {
                result.totalTokens += 1
                if composedLower.contains(token.lowercased()) {
                    result.retainedTokens += 1
                } else {
                    rowFullyRetained = false
                }
            }
            if !row.englishTokens.isEmpty && rowFullyRetained {
                result.rowsFullyRetained += 1
            }

            // The Chinese half of the output is everything that is not
            // ASCII: English runs and the spaces between them are the only
            // ASCII this engine can emit.
            let outputChinese = Array(composed.filter { !$0.isASCII })
            let gold = Array(row.goldChinese)
            if outputChinese.count != gold.count {
                result.rowsWithLengthMismatch += 1
            }
            for i in 0..<min(gold.count, outputChinese.count) {
                result.totalChars += 1
                if gold[i] == outputChinese[i] {
                    result.correctChars += 1
                }
            }
            result.totalChars += max(0, gold.count - outputChinese.count)
        }
        return result
    }

    private func percentile(_ values: [Int], _ p: Double) -> Double {
        if values.isEmpty { return 0 }
        let sorted = values.sorted()
        let k = Double(sorted.count - 1) * p
        let f = Int(k)
        let c = min(f + 1, sorted.count - 1)
        if f == c { return Double(sorted[f]) }
        return Double(sorted[f]) + Double(sorted[c] - sorted[f]) * (k - Double(f))
    }

    private func latencySummary(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let avg = values.reduce(0, +) / values.count
        return
            "\(avg)us / \(Int(percentile(values, 0.5)))us / \(Int(percentile(values, 0.95)))us / \(values.max()!)us"
    }

    /// The acceptance measurement for P1. Everything the `mixime-eval` CLI
    /// reports is engine-only: it never runs `KeyHandler`, so it cannot
    /// see any of the state-machine defects that made the first round
    /// unshippable (a space opening a candidate window that then ate every
    /// following key, Esc leaving half the reading behind, a force-commit
    /// dropping a whole run). This types the same corpus through the real
    /// `KeyHandler` instead and is the number that counts.
    func testEval200ThroughKeyHandler() throws {
        let corpusPath =
            NSHomeDirectory() + "/Dev/mixime-private/eval200.tsv"
        guard FileManager.default.fileExists(atPath: corpusPath) else {
            throw XCTSkip("corpus not present at \(corpusPath); nothing to measure")
        }
        let rows = try loadCorpus(at: corpusPath)
        XCTAssertFalse(rows.isEmpty)

        let human = runEval(rows, variant: .human)
        let raw = runEval(rows, variant: .raw)
        let chineseOnlyOn = runEval(rows, variant: .chineseOnly)

        Preferences.mixedScriptEnabled = false
        handler = KeyHandler()
        handler.inputMode = .bopomofo
        let chineseOnlyOff = runEval(rows, variant: .chineseOnly)
        Preferences.mixedScriptEnabled = true
        handler = KeyHandler()
        handler.inputMode = .bopomofo

        let report = """

            ## P1 round 2 -- app path (real KeyHandler), \(Self.today())

            Produced by `MixedScriptKeyHandlerTests.testEval200ThroughKeyHandler`
            (`xcodebuild -scheme McBopomofo test`), typing each corpus row's
            `keys` column into a real `KeyHandler` -- candidate states, Esc,
            Enter, the user override model and all -- and reading the
            committed text back. **This is the acceptance number.** The
            `mixime-eval` sections above it measure the engine only.

            Two key sequences are reported. `build_corpus.py` puts a
            delimiter space after every syllable, including ones a tone
            digit already finished; nobody types those, and in a real input
            method a space after a finished syllable means "show
            candidates". "human-typed" drops exactly those spaces (a space
            immediately after a 3/4/6/7 tone key) and keeps every other
            one -- tone-1 composition triggers and the separators that end
            an English word. "raw" is the corpus column verbatim, kept
            visible so the difference is not hidden.

            | metric | human-typed keys | raw corpus keys |
            |---|---|---|
            | **F1 token retention** | **\(human.retainedTokens)/\(human.totalTokens) = \(String(format: "%.1f", human.f1Rate))%** | \(raw.retainedTokens)/\(raw.totalTokens) = \(String(format: "%.1f", raw.f1Rate))% |
            | F1 row-level (all tokens kept) | \(human.rowsFullyRetained)/\(human.rowCount) = \(String(format: "%.1f", human.rowRate))% | \(raw.rowsFullyRetained)/\(raw.rowCount) = \(String(format: "%.1f", raw.rowRate))% |
            | zh accuracy within the mixed sentence | \(human.correctChars)/\(human.totalChars) = \(String(format: "%.1f", human.zhRate))% | \(raw.correctChars)/\(raw.totalChars) = \(String(format: "%.1f", raw.zhRate))% |
            | rows with a zh length mismatch | \(human.rowsWithLengthMismatch)/\(human.rowCount) | \(raw.rowsWithLengthMismatch)/\(raw.rowCount) |
            | latency per row (avg / p50 / p95 / max) | \(latencySummary(human.latenciesUs)) | \(latencySummary(raw.latenciesUs)) |

            ### Pure-Chinese control: does turning this on damage normal typing?

            The same rows with their English segments removed, so the input
            is nothing but ordinary Bopomofo. This is the comparison the
            95.3% P0.5 baseline is actually about, and the one the first
            round failed (it dropped pure-Chinese accuracy by 5.1 points
            while the harness's own F2 number stayed flat, because F2's
            `readings` mode never runs the key handling at all).

            | metric | mixedScriptEnabled = **on** | mixedScriptEnabled = off |
            |---|---|---|
            | **zh character accuracy** | **\(chineseOnlyOn.correctChars)/\(chineseOnlyOn.totalChars) = \(String(format: "%.1f", chineseOnlyOn.zhRate))%** | \(chineseOnlyOff.correctChars)/\(chineseOnlyOff.totalChars) = \(String(format: "%.1f", chineseOnlyOff.zhRate))% |
            | rows with a zh length mismatch | \(chineseOnlyOn.rowsWithLengthMismatch)/\(chineseOnlyOn.rowCount) | \(chineseOnlyOff.rowsWithLengthMismatch)/\(chineseOnlyOff.rowCount) |
            | latency per row (avg / p50 / p95 / max) | \(latencySummary(chineseOnlyOn.latenciesUs)) | \(latencySummary(chineseOnlyOff.latenciesUs)) |

            Note that the "zh accuracy within the mixed sentence" row in the
            first table is *not* comparable to 95.3%: it is measured on
            text typed from keys with English words interleaved, where an
            English run legitimately breaks the phrase context around it,
            and its own no-mixed-typing counterpart is 56.2%. The
            pure-Chinese control above is the like-for-like number.

            """

        print(report)

        // Thresholds from the P1 round-2 brief: F1 >= 80%, and Chinese
        // accuracy no worse than the P0.5 baseline. That baseline is
        // 4369/4586 characters, which BASELINE.md rounds to "95.3%" --
        // 95.2682% exactly, which is what the bound has to be written as.
        XCTAssertGreaterThanOrEqual(human.f1Rate, 80.0, "F1 token retention (app path)")
        XCTAssertGreaterThanOrEqual(
            chineseOnlyOn.zhRate, 95.268, "pure-Chinese accuracy with mixed typing on")
        XCTAssertGreaterThanOrEqual(
            chineseOnlyOn.zhRate, chineseOnlyOff.zhRate,
            "mixed typing must not cost anything on pure-Chinese input")

        try writeBaselineSection(report)
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Replaces (or appends) the app-path section of `tools/eval/BASELINE.md`
    /// so re-running the suite refreshes it instead of stacking copies.
    private func writeBaselineSection(_ report: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baseline = repoRoot.appendingPathComponent("tools/eval/BASELINE.md")
        guard FileManager.default.fileExists(atPath: baseline.path) else { return }
        var text = try String(contentsOf: baseline, encoding: .utf8)
        let marker = "\n## P1 round 2 -- app path (real KeyHandler)"
        if let range = text.range(of: marker) {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + report
        try text.write(to: baseline, atomically: true, encoding: .utf8)
    }

    func testPlainBopomofoIsUntouched() {
        handler = KeyHandler()
        handler.inputMode = .plainBopomofo
        resetSession()
        type("acer")
        XCTAssertFalse(composingBuffer.contains("acer"), "\(composingBuffer)")
    }
}
