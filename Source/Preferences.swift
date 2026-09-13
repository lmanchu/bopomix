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

import Cocoa

private let kKeyboardLayoutPreferenceKey = "KeyboardLayout"
/// alphanumeric ("ASCII") input basic keyboard layout.
private let kBasisKeyboardLayoutPreferenceKey = "BasisKeyboardLayout"
/// alphanumeric ("ASCII") input basic keyboard layout.
private let kFunctionKeyKeyboardLayoutPreferenceKey = "FunctionKeyKeyboardLayout"
/// whether include shift.
private let kFunctionKeyKeyboardLayoutOverrideIncludeShiftKey =
    "FunctionKeyKeyboardLayoutOverrideIncludeShift"
private let kCandidateListTextSizeKey = "CandidateListTextSize"
private let kSelectPhraseAfterCursorAsCandidateKey = "SelectPhraseAfterCursorAsCandidate"
private let kMoveCursorAfterSelectingCandidateKey = "MoveCursorAfterSelectingCandidate"
private let kUseHorizontalCandidateListPreferenceKey = "UseHorizontalCandidateList"
private let kChooseCandidateUsingSpaceKey = "ChooseCandidateUsingSpaceKey"
private let kChineseConversionEnabledKey = "ChineseConversionEnabled"
private let kHalfWidthPunctuationEnabledKey = "HalfWidthPunctuationEnable"
private let kEscToCleanInputBufferKey = "EscToCleanInputBuffer"
private let kKeepReadingUponCompositionError = "KeepReadingUponCompositionError"
// P1 zh/en mixed typing (see the design notes). No UI
// yet (planned for P4) -- these are UserDefaults-only for now, per
// AGENTS.md's Preferences convention.
private let kMixedScriptEnabledKey = "MixedScriptEnabled"
private let kMixedScriptLatinOnSpaceForUserWordsKey = "MixedScriptLatinOnSpaceForUserWords"
// P3 English prediction + Tab completion (see the design notes' F3
// scope). Gated on kMixedScriptEnabledKey too (see KeyHandler's
// _mixedScriptAvailable) -- this only decides whether completion runs on
// top of an already-available mixedScript run.
private let kLatinCompletionEnabledKey = "LatinCompletionEnabled"
// P3 fix #2 (see the design notes' P3 fix #2): learn from Latin
// runs actually typed and committed, not only from an explicit Tab/
// candidate-window completion accept.
private let kLatinLearnTypedWordsKey = "LatinLearnTypedWords"

private let kCandidateTextFontName = "CandidateTextFontName"
private let kCandidateKeyLabelFontName = "CandidateKeyLabelFontName"
private let kCandidateKeys = "CandidateKeys"
private let kAllowMovingCursorWhenChoosingCandidates = "AllowMovingCursorWhenChoosingCandidates"

private let kPhraseReplacementEnabledKey = "PhraseReplacementEnabled"
private let kChineseConversionStyleKey = "ChineseConversionStyle"
private let kAssociatedPhrasesEnabledKey = "AssociatedPhrasesEnabled"
private let kLetterBehaviorKey = "LetterBehavior"
private let kControlEnterOutputKey = "ControlEnterOutput"
private let kShiftEnterEnabledKey = "ShiftEnterEnabled"
private let kRepeatedPunctuationToSelectCandidateEnabledKey =
    "RepeatedPunctuationToSelectCandidateEnabled"
private let kUseCustomUserPhraseLocation = "UseCustomUserPhraseLocation"
private let kCustomUserPhraseLocation = "CustomUserPhraseLocation"

private let kDefaultCandidateListTextSize: CGFloat = 16
private let kMinCandidateListTextSize: CGFloat = 12
private let kMaxCandidateListTextSize: CGFloat = 196

private let kDefaultKeys = "123456789"
private let kDefaultAssociatedPhrasesKeys = "!@#$%^&*("

private let kAddPhraseHookEnabledKey = "AddPhraseHookEnabled"
private let kAddPhraseHookPath = "AddPhraseHookPath"

private let kSelectCandidateWithNumericKeypad = "SelectCandidateWithNumericKeypad"
private let kBig5InputEnabledKey = "Big5InputEnabled"

// Need to be populated to true by default upon first start, so the key is not private.
let kBeepUponInputErrorKey = "BeepUponInputError"

private let kEnableUserPhrasesInPlainBopomofo = "EnableUserPhrasesInPlainBopomofo"
private let kAllowChangingPriorTone = "AllowChangingPriorTone"

private let kBopomofoFontAnnotationSupportEnabled = "BopomofoFontAnnotationSupportEnabled"
private let kShowBopomofoFontAnnotationSupportItemInInputMenu =
    "ShowBopomofoFontAnnotationSupportItemInInputMenu"
private let kBopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1 =
    "BopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1"

// MARK: Property wrappers

@propertyWrapper
struct UserDefault<Value> {
    let key: String
    let defaultValue: Value
    var container: UserDefaults = .standard

    var wrappedValue: Value {
        get {
            container.object(forKey: key) as? Value ?? defaultValue
        }
        set {
            container.set(newValue, forKey: key)
        }
    }
}

@propertyWrapper
struct UserDefaultWithFunction<Value> {
    let key: String
    let defaultValueFunction: () -> Value
    var container: UserDefaults = .standard

    var wrappedValue: Value {
        get {
            container.object(forKey: key) as? Value ?? defaultValueFunction()
        }
        set {
            container.set(newValue, forKey: key)
        }
    }
}

@propertyWrapper
struct EnumUserDefault<T: RawRepresentable> {
    let key: String
    let defaultValue: T
    var container: UserDefaults = .standard

    var wrappedValue: T {
        get {
            if let value = container.object(forKey: key) as? T.RawValue {
                return T(rawValue: value) ?? defaultValue
            }
            return defaultValue
        }
        set {
            container.set(newValue.rawValue, forKey: key)
        }
    }
}

@propertyWrapper
struct CandidateListTextSize {
    let key: String
    let defaultValue: CGFloat = kDefaultCandidateListTextSize
    lazy var container: UserDefault = {
        UserDefault(key: key, defaultValue: defaultValue)
    }()

    var wrappedValue: CGFloat {
        mutating get {
            var value = container.wrappedValue
            if value < kMinCandidateListTextSize {
                value = kMinCandidateListTextSize
            } else if value > kMaxCandidateListTextSize {
                value = kMaxCandidateListTextSize
            }
            return value
        }
        set {
            var value = newValue
            if value < kMinCandidateListTextSize {
                value = kMinCandidateListTextSize
            } else if value > kMaxCandidateListTextSize {
                value = kMaxCandidateListTextSize
            }
            container.wrappedValue = value
        }
    }
}

// MARK: -

@objc enum KeyboardLayout: Int {
    case standard = 0
    case eten = 1
    case hsu = 2
    case eten26 = 3
    case hanyuPinyin = 4
    case IBM = 5

    var name: String {
        return switch self {
        case .standard:
            "Standard"
        case .eten:
            "ETen"
        case .hsu:
            "Hsu"
        case .eten26:
            "ETen26"
        case .hanyuPinyin:
            "HanyuPinyin"
        case .IBM:
            "IBM"
        }
    }
}

@objc enum ChineseConversionStyle: Int {
    case output
    case model

    var name: String {
        return switch self {
        case .output:
            "output"
        case .model:
            "model"
        }
    }
}

// MARK: -

class Preferences: NSObject {
    static var allKeys: [String] {
        [
            kKeyboardLayoutPreferenceKey,
            kBasisKeyboardLayoutPreferenceKey,
            kFunctionKeyKeyboardLayoutPreferenceKey,
            kFunctionKeyKeyboardLayoutOverrideIncludeShiftKey,
            kCandidateListTextSizeKey,
            kSelectPhraseAfterCursorAsCandidateKey,
            kUseHorizontalCandidateListPreferenceKey,
            kChooseCandidateUsingSpaceKey,
            kChineseConversionEnabledKey,
            kHalfWidthPunctuationEnabledKey,
            kEscToCleanInputBufferKey,
            kKeepReadingUponCompositionError,
            kCandidateTextFontName,
            kCandidateKeyLabelFontName,
            kCandidateKeys,
            kPhraseReplacementEnabledKey,
            kChineseConversionStyleKey,
            kAssociatedPhrasesEnabledKey,
            kControlEnterOutputKey,
            kShiftEnterEnabledKey,
            kRepeatedPunctuationToSelectCandidateEnabledKey,
            kUseCustomUserPhraseLocation,
            kCustomUserPhraseLocation,
            kMixedScriptEnabledKey,
            kMixedScriptLatinOnSpaceForUserWordsKey,
            kLatinCompletionEnabledKey,
            kLatinLearnTypedWordsKey,
        ]
    }

    /// True when this process is an XCTest run rather than the input
    /// method itself.
    ///
    /// The Bopomix app bundle *is* the XCTest host, so `main.swift`
    /// runs in full before a single test does -- including
    /// `populateDefaults()`, which unconditionally wrote 23 keys into the
    /// real `io.github.lmanchu.inputmethod.bopomix` domain. Those writes
    /// happen before `PreferenceSandbox` can take its snapshot, so they
    /// are restored rather than removed, and one of them (a build-tree
    /// `AddPhraseHookPath`) outlived the build directory it pointed at
    /// (docs/REVERIFY-P3-2026-09-12.md's P-3).
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner in the
    /// host's environment and by nothing else.
    @objc static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @objc static func populateDefaults() {
        Preferences.keyboardLayout = Preferences.keyboardLayout
        Preferences.basisKeyboardLayout = Preferences.basisKeyboardLayout
        Preferences.functionKeyboardLayout = Preferences.functionKeyboardLayout
        Preferences.candidateKeys = Preferences.candidateKeys
        Preferences.selectPhraseAfterCursorAsCandidate =
            Preferences.selectPhraseAfterCursorAsCandidate
        Preferences.moveCursorAfterSelectingCandidate =
            Preferences.moveCursorAfterSelectingCandidate
        Preferences.useHorizontalCandidateList = Preferences.useHorizontalCandidateList
        Preferences.chineseConversionEnabled = Preferences.chineseConversionEnabled
        Preferences.halfWidthPunctuationEnabled = Preferences.halfWidthPunctuationEnabled
        Preferences.selectCandidateWithNumericKeypad = Preferences.selectCandidateWithNumericKeypad
        Preferences.big5InputEnabled = Preferences.big5InputEnabled
        Preferences.chineseConversionStyle = Preferences.chineseConversionStyle
        Preferences.phraseReplacementEnabled = Preferences.phraseReplacementEnabled
        Preferences.associatedPhrasesEnabled = Preferences.associatedPhrasesEnabled
        Preferences.letterBehavior = Preferences.letterBehavior
        Preferences.controlEnterOutput = Preferences.controlEnterOutput
        Preferences.shiftEnterEnabled = Preferences.shiftEnterEnabled
        Preferences.repeatedPunctuationToSelectCandidateEnabled =
            Preferences.repeatedPunctuationToSelectCandidateEnabled
        Preferences.addPhraseHookEnabled = Preferences.addPhraseHookEnabled
        Preferences.addPhraseHookPath = Preferences.addPhraseHookPath
        Preferences.beepUponInputError = Preferences.beepUponInputError
        Preferences.enableUserPhrasesInPlainBopomofo = Preferences.enableUserPhrasesInPlainBopomofo
        Preferences.allowMovingCursorWhenChoosingCandidates =
            Preferences.allowMovingCursorWhenChoosingCandidates
    }

    @EnumUserDefault(key: kKeyboardLayoutPreferenceKey, defaultValue: KeyboardLayout.standard)
    @objc static var keyboardLayout: KeyboardLayout

    @objc static var keyboardLayoutName: String {
        keyboardLayout.name
    }

    @UserDefault(key: kBasisKeyboardLayoutPreferenceKey, defaultValue: "com.apple.keylayout.US")
    @objc static var basisKeyboardLayout: String

    @UserDefault(
        key: kFunctionKeyKeyboardLayoutPreferenceKey, defaultValue: "com.apple.keylayout.US")
    @objc static var functionKeyboardLayout: String

    @UserDefault(key: kFunctionKeyKeyboardLayoutOverrideIncludeShiftKey, defaultValue: false)
    @objc static var functionKeyKeyboardLayoutOverrideIncludeShiftKey: Bool

    @CandidateListTextSize(key: kCandidateListTextSizeKey)
    @objc static var candidateListTextSize: CGFloat

    @UserDefault(key: kSelectPhraseAfterCursorAsCandidateKey, defaultValue: false)
    @objc static var selectPhraseAfterCursorAsCandidate: Bool

    @UserDefault(key: kMoveCursorAfterSelectingCandidateKey, defaultValue: false)
    @objc static var moveCursorAfterSelectingCandidate: Bool

    @UserDefault(key: kUseHorizontalCandidateListPreferenceKey, defaultValue: false)
    @objc static var useHorizontalCandidateList: Bool

    @UserDefault(key: kChooseCandidateUsingSpaceKey, defaultValue: true)
    @objc static var chooseCandidateUsingSpace: Bool

    @UserDefault(key: kChineseConversionEnabledKey, defaultValue: false)
    @objc static var chineseConversionEnabled: Bool

    @objc static func toggleChineseConversionEnabled() -> Bool {
        chineseConversionEnabled = !chineseConversionEnabled
        return chineseConversionEnabled
    }

    @UserDefault(key: kHalfWidthPunctuationEnabledKey, defaultValue: false)
    @objc static var halfWidthPunctuationEnabled: Bool

    @objc static func toggleHalfWidthPunctuationEnabled() -> Bool {
        halfWidthPunctuationEnabled = !halfWidthPunctuationEnabled
        return halfWidthPunctuationEnabled
    }

    @UserDefault(key: kEscToCleanInputBufferKey, defaultValue: false)
    @objc static var escToCleanInputBuffer: Bool

    @UserDefault(key: kKeepReadingUponCompositionError, defaultValue: false)
    @objc static var keepReadingUponCompositionError: Bool

    // MARK: P1 zh/en mixed typing (see the design notes)

    /// Master switch for zh/en mixed typing. On by default -- it is what
    /// Bopomix is for; `defaults write io.github.lmanchu.inputmethod.bopomix
    /// MixedScriptEnabled -bool false` turns it off. Off, every mixedScript
    /// code path short-circuits and the input method behaves exactly like
    /// upstream McBopomofo.
    @UserDefault(key: kMixedScriptEnabledKey, defaultValue: true)
    @objc static var mixedScriptEnabled: Bool

    /// Whether a run that is a word in the user's *own* Latin lexicon
    /// (`latin-user.txt` -- words they previously picked as English with
    /// Tab or the candidate window) auto-commits as English when it is
    /// followed by a space, instead of staying Chinese with the English
    /// form on the candidate window's second row.
    ///
    /// This used to apply to the whole 200k-word built-in dictionary
    /// ("詞典＋空白→英文", 2026-09-09). That is unworkable on this
    /// layout, because space is also how a tone-1 syllable is composed:
    /// "up ", "el ", "fu/ " stopped producing 因/高/清. Narrowed on
    /// 2026-09-10 to words the user has personally disambiguated at least
    /// once (see MixedScriptTracker::onBoundary() and
    /// docs/REVIEW-P1-2026-09-10.md's B1/B2). Rule A (structurally
    /// impossible Bopomofo shape) is unaffected either way.
    @UserDefault(key: kMixedScriptLatinOnSpaceForUserWordsKey, defaultValue: true)
    @objc static var mixedScriptLatinOnSpaceForUserWords: Bool

    // MARK: P3 English prediction + Tab completion (see
    // the design notes' F3 scope)

    /// Whether a Latin run shows a top-1 completion tooltip and Tab/
    /// Shift+Tab accept/cycle it. Defaults to on (unlike
    /// mixedScriptEnabled's P1 opt-in): with mixedScriptEnabled already
    /// off, this preference is unreachable (see KeyHandler's
    /// _mixedScriptAvailable), so it only ever takes effect for someone
    /// who has already turned P1 on -- turning it off on top of that is
    /// the opt-out, not the opt-in.
    @UserDefault(key: kLatinCompletionEnabledKey, defaultValue: true)
    @objc static var latinCompletionEnabled: Bool

    /// Whether a Rule-A Latin run that reaches an ordinary boundary commit
    /// (Enter, space, punctuation, or a Shift+letter starting the next
    /// word -- see KeyHandler's _commitMixedScriptLatinRun) can be written
    /// into the user's own Latin lexicon (`latin-user.txt`), so words the
    /// user actually types -- not just words they accept a prediction for
    /// -- start ranking ahead of the built-in dictionary.
    ///
    /// A committed run is a *candidate*, not an entry. The rules, in
    /// KeyHandler's `_learnTypedLatinWordIfEligible:`:
    ///
    ///  * 3-20 lowercase ASCII letters, or it is ignored outright;
    ///  * a run the lexicon already knows (dictionary, tech seed, or a
    ///    word this user has learned before) is recorded immediately, and
    ///    needs a second sighting before it outranks the dictionary;
    ///  * anything else is held **in memory only** and reaches the file
    ///    after it has been committed twice, in two separate commits.
    ///
    /// That last rule is the one that matters, because a run cannot
    /// report on itself: a locked Rule-A run keeps absorbing letters
    /// until a non-letter key, so "acersu" -- an English word with the
    /// start of a Chinese syllable glued on -- looks exactly like a new
    /// word the first time. Requiring the identical string twice is the
    /// only available signal. Without it, one typo owned its prefix
    /// permanently (docs/REVIEW-P3-2026-09-11.md's B2).
    ///
    /// Privacy: only a run that is actually committed counts (Esc or
    /// Backspace canceling it never reaches this hook at all), nothing
    /// about Bopomofo/Chinese input is ever written this way, a
    /// Shift-typed forced-uppercase word (the separate pre-existing
    /// upstream "force English" gesture) is never seen by this hook, and
    /// turning `latinCompletionEnabled` off stops the writes as well as
    /// the predictions. Defaults to on, matching latinCompletionEnabled
    /// -- with mixedScriptEnabled already off, this preference is
    /// unreachable, so it only ever takes effect on top of P1 already
    /// being turned on. The file is plain text: to forget something, edit
    /// or delete `latin-user.txt` in the user-phrase folder.
    ///
    /// One undocumented-until-now escape hatch worth knowing
    /// (docs/REVIEW-P3-2026-09-11.md's N12): pressing Tab before ending a
    /// run suppresses learning for it even when Tab has no completion to
    /// offer, because Tab reaching the boundary path at all means "no
    /// completion was available", which is not the user choosing to
    /// finish this exact word. So `thq` + Enter stages a sighting;
    /// `thq` + Tab + Enter stages nothing.
    @UserDefault(key: kLatinLearnTypedWordsKey, defaultValue: true)
    @objc static var latinLearnTypedWords: Bool

    // MARK: Optional settings

    @UserDefault(key: kCandidateTextFontName, defaultValue: nil)
    @objc static var candidateTextFontName: String?

    @UserDefault(key: kCandidateKeyLabelFontName, defaultValue: nil)
    @objc static var candidateKeyLabelFontName: String?

    @UserDefault(key: kCandidateKeys, defaultValue: kDefaultKeys)
    @objc static var candidateKeys: String

    @objc static var defaultCandidateKeys: String {
        kDefaultKeys
    }
    @objc static var suggestedCandidateKeys: [String] {
        [kDefaultKeys, "asdfghjkl", "asdfzxcvb"]
    }

    static func validate(candidateKeys: String) throws {
        let trimmed = candidateKeys.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CandidateKeyError.empty
        }
        if !trimmed.canBeConverted(to: .ascii) {
            throw CandidateKeyError.invalidCharacters
        }
        if trimmed.contains(" ") {
            throw CandidateKeyError.containSpace
        }
        if trimmed.count < 4 {
            throw CandidateKeyError.tooShort
        }
        if trimmed.count > 15 {
            throw CandidateKeyError.tooLong
        }
        let set = Set(Array(trimmed))
        if set.count != trimmed.count {
            throw CandidateKeyError.duplicatedCharacters
        }
    }

    enum CandidateKeyError: Error, LocalizedError {
        case empty
        case invalidCharacters
        case containSpace
        case duplicatedCharacters
        case tooShort
        case tooLong

        var errorDescription: String? {
            switch self {
            case .empty:
                return NSLocalizedString("Candidates keys cannot be empty.", comment: "")
            case .invalidCharacters:
                return NSLocalizedString(
                    "Candidate keys can only contain Latin characters and numbers.", comment: "")
            case .containSpace:
                return NSLocalizedString("Candidate keys cannot contain space.", comment: "")
            case .duplicatedCharacters:
                return NSLocalizedString("There should not be duplicated keys.", comment: "")
            case .tooShort:
                return NSLocalizedString(
                    "Candidate keys cannot be shorter than 4 characters.", comment: "")
            case .tooLong:
                return NSLocalizedString(
                    "Candidate keys cannot be longer than 15 characters.", comment: "")
            }
        }
    }
}

/// An enumeration representing keys used for moving the cursor in the
/// application.
@objc enum MovingCursorKey: Int {
    case disabled = 0
    case useJK = 1
    case useHL = 2
}

extension MovingCursorKey {
    var name: String {
        switch self {
        case .disabled: "Disabled"
        case .useJK: "J/K"
        case .useHL: "H/L"
        }
    }
}

extension Preferences {
    /// Whether allows moving the cursor by J/K or H/L keys, when the candidate
    /// window is presented.
    @EnumUserDefault(key: kAllowMovingCursorWhenChoosingCandidates, defaultValue: .disabled)
    @objc static var allowMovingCursorWhenChoosingCandidates: MovingCursorKey
}

extension Preferences {
    /// The conversion style.
    ///
    /// - 0: convert the output
    /// - 1: convert the phrase models.
    @EnumUserDefault(key: kChineseConversionStyleKey, defaultValue: ChineseConversionStyle.output)
    @objc static var chineseConversionStyle: ChineseConversionStyle

    @objc static var chineseConversionStyleName: String {
        chineseConversionStyle.name
    }
}

extension Preferences {

    @UserDefault(key: kPhraseReplacementEnabledKey, defaultValue: false)
    @objc static var phraseReplacementEnabled: Bool

    @objc static func togglePhraseReplacementEnabled() -> Bool {
        phraseReplacementEnabled = !phraseReplacementEnabled
        return phraseReplacementEnabled
    }

    @UserDefault(key: kAssociatedPhrasesEnabledKey, defaultValue: false)
    @objc static var associatedPhrasesEnabled: Bool

    @objc static func toggleAssociatedPhrasesEnabled() -> Bool {
        associatedPhrasesEnabled = !associatedPhrasesEnabled
        return associatedPhrasesEnabled
    }

    @UserDefault(key: kShiftEnterEnabledKey, defaultValue: true)
    @objc static var shiftEnterEnabled: Bool

    @UserDefault(key: kRepeatedPunctuationToSelectCandidateEnabledKey, defaultValue: false)
    @objc static var repeatedPunctuationToSelectCandidateEnabled: Bool
}

@objc enum ControlEnterOutput: Int {
    case off = 0
    case bpmfReading = 1
    case htmlRuby = 2
    case brailleUnicode = 3
    case hanyuPinyin = 4
    case brailleAscii = 5
}

extension ControlEnterOutput {
    var name: String {
        switch self {
        case .off: "Off"
        case .bpmfReading: "Bopomofo Reading"
        case .htmlRuby: "HTML Ruby Text"
        case .brailleUnicode: "Taiwanese Braille (Unicode)"
        case .brailleAscii: "Taiwanese Braille (ASCII)"
        case .hanyuPinyin: "Hanyu Pinyin"
        }
    }
}

extension Preferences {
    /// The behavior of pressing letter keys.
    ///
    /// - 0: Output upper-cased letters directly.
    /// - 1: Output lower-cased letters in the composing buffer.
    @UserDefault(key: kLetterBehaviorKey, defaultValue: 0)
    @objc static var letterBehavior: Int

    /// The behavior of pressing Ctrl + Enter.
    ///
    /// - 0: Disabled.
    /// - 1: Output BPMF readings.
    @EnumUserDefault(key: kControlEnterOutputKey, defaultValue: .off)
    @objc static var controlEnterOutput: ControlEnterOutput
}

@objc class UserPhraseLocationHelper: NSObject {
    @objc static var defaultUserPhraseLocation: String {
        let paths = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true)
        let appSupportPath = paths.first!
        return (appSupportPath as NSString).appendingPathComponent("Bopomix")
    }
}

extension NSNotification.Name {
    static var userPhraseLocationDidChange = NSNotification.Name(
        rawValue: "UserPhraseLocationDidChangeNotification")
}

extension Preferences {

    static func postUserPhraseLocationNotification() {
        let location: String = {
            if !useCustomUserPhraseLocation {
                return UserPhraseLocationHelper.defaultUserPhraseLocation
            }
            if customUserPhraseLocation.isEmpty {
                return UserPhraseLocationHelper.defaultUserPhraseLocation
            }
            return customUserPhraseLocation
        }()
        let notification = Notification(
            name: .userPhraseLocationDidChange, object: self,
            userInfo: [
                "location": location
            ])
        NotificationQueue.default.dequeueNotifications(matching: notification, coalesceMask: 0)
        NotificationQueue.default.enqueue(notification, postingStyle: .now)
    }

    @UserDefault(key: kUseCustomUserPhraseLocation, defaultValue: false)
    @objc static var useCustomUserPhraseLocation: Bool {
        didSet {
            postUserPhraseLocationNotification()
        }
    }

    @UserDefault(key: kCustomUserPhraseLocation, defaultValue: "")
    @objc static var customUserPhraseLocation: String {
        didSet {
            postUserPhraseLocationNotification()
        }
    }
}

extension Preferences {
    static func defaultAddPhraseHookPath() -> String {
        let bundle = Bundle.main
        let hookPath = bundle.path(forResource: "add-phrase-hook", ofType: "sh")
        return hookPath!
    }

    @UserDefault(key: kAddPhraseHookEnabledKey, defaultValue: false)
    @objc static var addPhraseHookEnabled: Bool

    @UserDefaultWithFunction(
        key: kAddPhraseHookPath, defaultValueFunction: defaultAddPhraseHookPath)
    @objc static var addPhraseHookPath: String
}

extension Preferences {
    @UserDefault(key: kSelectCandidateWithNumericKeypad, defaultValue: false)
    @objc static var selectCandidateWithNumericKeypad: Bool
}

extension Preferences {
    @UserDefault(key: kBig5InputEnabledKey, defaultValue: true)
    @objc static var big5InputEnabled: Bool
}

extension Preferences {
    @UserDefault(key: kBeepUponInputErrorKey, defaultValue: true)
    @objc static var beepUponInputError: Bool
}

extension Preferences {
    @UserDefault(key: kEnableUserPhrasesInPlainBopomofo, defaultValue: false)
    @objc static var enableUserPhrasesInPlainBopomofo: Bool
}

extension Preferences {
    @UserDefault(key: kAllowChangingPriorTone, defaultValue: false)
    @objc static var allowChangingPriorTone: Bool
}

extension Preferences {
    // Whether to enable Bopomofo Font Annotation Support.
    @UserDefault(key: kBopomofoFontAnnotationSupportEnabled, defaultValue: false)
    @objc static var bopomofoFontAnnotationSupportEnabled: Bool

    @objc static func toggleBopomofoFontAnnotationSupportEnabled() -> Bool {
        bopomofoFontAnnotationSupportEnabled = !bopomofoFontAnnotationSupportEnabled
        return bopomofoFontAnnotationSupportEnabled
    }

    // Whether to show the "Bopomofo Font Annotation Support" toggle in the input menu.
    @UserDefault(key: kShowBopomofoFontAnnotationSupportItemInInputMenu, defaultValue: false)
    @objc static var showBopomofoFontAnnotationSupportItemInInputMenu: Bool

    // Whether at first launch, we have checked if there are any bpmfvs-supporting fonts installed,
    // and enable showBopomofoFontAnnotationSupportItemInInputMenu as a result. No more check is
    // performed once this flag is turned to true.
    @UserDefault(
        key: kBopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1,
        defaultValue: false)
    @objc static var bopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1: Bool
}

extension Preferences {
    static func createReport() -> String {
        var lines: [String] = []
        lines.append("- Bopomix Settings")
        lines.append("  - Keyboard Layout: \(Preferences.keyboardLayout.name)")
        lines.append("  - Basis Keyboard Layout: \(Preferences.basisKeyboardLayout)")
        lines.append("  - Function Keyboard Layout: \(Preferences.functionKeyboardLayout)")
        lines.append("  - Candidate Keys: \(Preferences.candidateKeys)")
        lines.append(
            "  - Selection Mode: \(Preferences.selectPhraseAfterCursorAsCandidate ? "After Cursor" : "Before Cursor")"
        )
        lines.append(
            "  - Move Cursor After Selecting Candidate: \(Preferences.moveCursorAfterSelectingCandidate ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Candidate Window: \(Preferences.useHorizontalCandidateList ? "Horizontal" : "Vertical")"
        )
        lines.append(
            "  - Chinese Conversion: \(Preferences.chineseConversionEnabled ? "Enabled" : "Disabled")"
        )
        lines
            .append(
                "  - Chinese Conversion Style: \(Preferences.chineseConversionStyle.name)"
            )
        lines.append(
            "  - Punctuations: \(Preferences.halfWidthPunctuationEnabled ? "Half-width" : "Full-width")"
        )
        lines.append(
            "  - Select Candidate With Numeric Keyboard: \(Preferences.selectCandidateWithNumericKeypad ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Allow Ctrl + ` For Big5 Input: \(Preferences.big5InputEnabled ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Phrase Replacement: \(Preferences.phraseReplacementEnabled ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Associated Phrases (McBopomofo): \(Preferences.associatedPhrasesEnabled ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Associated Phrases (Plain Bopomofo): \(Preferences.enableUserPhrasesInPlainBopomofo ? "Enabled" : "Disabled")"
        )

        lines.append("  - Letter Keys: \(Preferences.letterBehavior)")
        lines.append("  - Ctrl + Enter Key: \(Preferences.controlEnterOutput.name)")
        lines.append(
            "  - Shift + Enter Key For Associated Phrases: \(Preferences.shiftEnterEnabled ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Repeated Keys For Next Candidate: \(Preferences.repeatedPunctuationToSelectCandidateEnabled ? "Enabled" : "Disabled")"
        )
        lines.append(
            "  - Add Phrase Hook: \(Preferences.addPhraseHookEnabled ? "Enabled" : "Disabled")")
        lines.append("  - Add Phrase Hook Path: \(Preferences.addPhraseHookPath)")
        lines.append(
            "  - Beep Upon Errors: \(Preferences.beepUponInputError ? "Enabled" : "Disabled")")
        lines.append(
            "  - Moving Cursor When Choosing Candidates: \(Preferences.allowMovingCursorWhenChoosingCandidates)"
        )
        return lines.joined(separator: "\n")
    }
}
