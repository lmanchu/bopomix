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

/// Protects the *developer's own* input-method preferences from the test
/// suite (docs/REVIEW-P3-2026-09-11.md's N4).
///
/// Every `Preferences.foo = ...` writes straight through to the real
/// `org.openvanilla.inputmethod.McBopomofo` defaults domain -- the same
/// file the installed input method reads (`UserDefault`'s setter is an
/// unconditional `UserDefaults.standard.set`). The per-property
/// save-in-setUp / restore-in-tearDown pattern the KeyHandler test classes
/// used is not enough for two reasons:
///
///  * writing a saved value back still *creates* a key that was never in
///    the file to begin with, so a suite run left e.g.
///    `UseCustomUserPhraseLocation = 0` and `CustomUserPhraseLocation =
///    ""` behind on a machine that had neither; and
///  * a test that fails (or throws) part-way through skips a
///    `tearDownWithError` body entirely, so whatever it had set stayed
///    set. That is how a `$TMPDIR` path once became the live
///    `CustomUserPhraseLocation` on the author's own machine and the
///    installed input method started writing learned phrases into a
///    folder macOS periodically deletes.
///
/// This snapshots the whole persistent domain instead of individual keys,
/// so keys the test *adds* are removed again, and installs the restore
/// through `addTeardownBlock`, which XCTest runs even when the test fails,
/// throws, or the class's own `tearDownWithError` is never reached.
///
/// Usage: call `PreferenceSandbox.install(on: self)` as the *first*
/// statement of `setUpWithError()`, before touching `Preferences` at all.
/// Verify with `tools/eval/check_plist_unchanged.sh`, which fails the
/// moment a suite run changes a single key.
enum PreferenceSandbox {

    /// The app host's own domain -- `Preferences` writes to
    /// `UserDefaults.standard`, which for the McBopomofo test host is
    /// this domain.
    private static var domainName: String {
        Bundle.main.bundleIdentifier ?? "org.openvanilla.inputmethod.McBopomofo"
    }

    /// Captured once, the first time any test installs the sandbox, and
    /// reused for every test after that.
    ///
    /// Deliberately not re-read per test: `PreferencesTests` (swift-testing,
    /// same process) removes *every* key in the domain in its initializer
    /// and puts them back in `deinit`, so a snapshot taken while that is in
    /// flight would record an empty domain -- and restoring that would wipe
    /// the developer's real settings rather than protect them. The
    /// process's starting state is the only thing worth restoring to
    /// anyway.
    private static var processStartSnapshot: [String: Any]??

    static func install(on testCase: XCTestCase) {
        let defaults = UserDefaults.standard
        let name = domainName
        if processStartSnapshot == nil {
            processStartSnapshot = .some(defaults.persistentDomain(forName: name))
        }
        testCase.addTeardownBlock {
            guard let outer = processStartSnapshot, let saved = outer else {
                // No domain to restore. Deliberately *not*
                // removePersistentDomain here: wiping someone's real
                // settings is the one outcome this type exists to
                // prevent. A genuinely fresh machine (no domain at all at
                // process start) therefore keeps whatever the suite set,
                // which is the safe direction to fail in.
                return
            }
            defaults.setPersistentDomain(saved, forName: name)
        }
    }
}
