// Copyright (c) 2022 and onwards The McBopomofo Authors.
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

import Testing

@testable import Bopomix

@Suite("Associated Phrases Testing", .serialized)
final class AssociatedPhrasesTests {

    var handler = KeyHandler()

    /// The key name `Preferences.chineseConversionEnabled` is stored
    /// under. Duplicated from `kChineseConversionEnabledKey`
    /// (Preferences.swift), which is file-private; widening that just for
    /// a test is the worse trade, so keep the two in step by hand.
    private let chineseConversionKey = "ChineseConversionEnabled"

    init() async throws {
        // Restoring by reading the typed property here and assigning it
        // back in `deinit` looks symmetric but is not: the property
        // reports `false` for a key that was never in the file, so writing
        // it back **creates** the key. Nor is snapshotting the raw value
        // here enough -- this suite is swift-testing and runs
        // unserialized against the XCTest suites, several of which set
        // this same key in `setUpWithError()`, so "the value right now"
        // is whatever the runner's ordering happened to leave.
        //
        // PreferenceSandbox's snapshot is shared and taken once, by
        // whichever suite starts first, before any of them writes.
        PreferenceSandbox.captureNow()
        Preferences.chineseConversionEnabled = false
        LanguageModelManager.loadDataModels()
        handler = KeyHandler()
        handler.inputMode = .bopomofo
    }

    deinit {
        PreferenceSandbox.restore(key: chineseConversionKey)
    }

    private func typeKeys(_ keySequence: String) -> InputState {
        var state: InputState = InputState.Empty()
        let keys = Array(keySequence).map(String.init)
        for key in keys {
            let input = KeyHandlerInput(
                inputText: key, keyCode: 0, charCode: charCode(key), flags: [],
                isVerticalMode: false)
            handler.handle(input: input, state: state) { newState in
                state = newState
            } errorCallback: {
            }
        }
        return state
    }

    @Test(
        "Test building an associated phrase from characters",
        arguments: [
            ("u6", "ㄧ", "一")
        ])
    func testBuildingAssociatedPhrasesState(keySequence: String, reading: String, value: String) {
        let state = typeKeys(keySequence)
        let params = BuildAssociatedPhraseParams()
        params.previousState = state
        params.prefixCursorIndex = 1
        params.reading = reading
        params.value = value
        params.candidateIndex = 0
        params.useVerticalMode = false
        params.autoTriggered = false
        guard
            let associatedPhrases = handler.buildAssociatedPhraseState(with: params)
                as? InputState.AssociatedPhrases
        else {
            Issue.record("There should be an associated phrase state")
            return
        }
        #expect(associatedPhrases.candidates.count > 0)
    }

    @Test(
        "Test building an associated phrase from punctuations",
        arguments: [
            ("『", "『』"),
            ("《", "《》"),
        ])
    func testAssociatedPhrasesStatePunctuation1(input: String, result: String) {
        let state = typeKeys("{")
        let params = BuildAssociatedPhraseParams()
        params.previousState = state
        params.prefixCursorIndex = 1
        params.reading = "_punctuation_{"
        params.value = input
        params.candidateIndex = 0
        params.useVerticalMode = false
        params.autoTriggered = false
        guard
            let associatedPhrases = handler.buildAssociatedPhraseState(with: params)
                as? InputState.AssociatedPhrases
        else {
            Issue.record("There should be an associated phrase state")
            return
        }
        #expect(associatedPhrases.candidates.count > 0)
        let candidate = associatedPhrases.candidates[0]

        handler.fixNodeForAssociatedPhraseWithPrefix(
            at: associatedPhrases.prefixCursorIndex, prefixReading: associatedPhrases.prefixReading,
            prefixValue: associatedPhrases.prefixValue, associatedPhraseReading: candidate.reading,
            associatedPhraseValue: candidate.value)
        guard let inputting = handler.buildInputtingState() as? InputState.Inputting else {
            Issue.record("There should be an inputting state")
            return
        }
        #expect(inputting.composingBuffer == result)
    }

    @Test("Test building associated phrase state honors supported parameter object fields")
    func testBuildingAssociatedPhrasesStateHonorsSupportedParameterObjectFields() {
        let state = typeKeys("u6")
        let params = BuildAssociatedPhraseParams()
        params.previousState = state
        params.prefixCursorIndex = 1
        params.reading = "ㄧ"
        params.value = "一"
        params.candidateIndex = 1
        params.useVerticalMode = true
        params.autoTriggered = true

        guard
            let associatedPhrases = handler.buildAssociatedPhraseState(with: params)
                as? InputState.AssociatedPhrases
        else {
            Issue.record("There should be an associated phrase state")
            return
        }

        #expect(associatedPhrases.prefixCursorIndex == 1)
        #expect(associatedPhrases.prefixReading == "ㄧ")
        #expect(associatedPhrases.prefixValue == "一")
        #expect(associatedPhrases.selectedIndex == 1)
        #expect(associatedPhrases.useVerticalMode)
        #expect(associatedPhrases.autoTriggered)
        #expect(associatedPhrases.candidates.count > 0)
    }

}
