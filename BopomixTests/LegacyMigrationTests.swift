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

/// Covers the pure halves of `LegacyMigration` plus the folder copy
/// against a throwaway directory.
///
/// Deliberately touches neither `UserDefaults.standard` nor anything under
/// the real `~/Library`: `migrateIfNeeded()` itself is not exercised here,
/// because the whole point of the migration is to write into the live
/// preferences domain and the live Application Support folder, and a test
/// that did that would be doing the exact damage `PreferenceSandbox`
/// exists to prevent.
final class LegacyMigrationTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopomix-legacy-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox, FileManager.default.fileExists(atPath: sandbox.path) {
            try FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
    }

    // MARK: - preferencesToMigrate

    func testMigratesLegacyKeysTheNewDomainDoesNotHave() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["KeyboardLayout": 2, "CandidateKeys": "asdfghjkl"],
            current: [:])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["KeyboardLayout"] as? Int, 2)
        XCTAssertEqual(result["CandidateKeys"] as? String, "asdfghjkl")
    }

    func testDoesNotOverwriteKeysTheNewDomainAlreadyHas() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["KeyboardLayout": 2, "CandidateKeys": "asdfghjkl"],
            current: ["CandidateKeys": "123456789"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["KeyboardLayout"] as? Int, 2)
        XCTAssertNil(result["CandidateKeys"])
    }

    /// The blacklist is the load-bearing half of the migration's
    /// non-destructiveness: inheriting the two custom-location keys would
    /// put two live input methods on one user-phrase folder.
    func testNeverMigratesBlacklistedKeys() {
        let legacy: [String: Any] = [
            LegacyMigration.prefsMarkerKey: true,
            LegacyMigration.userDataMarkerKey: true,
            "UseCustomUserPhraseLocation": true,
            "CustomUserPhraseLocation": "/Users/someone/Dropbox/McBopomofo",
            "AddPhraseHookPath": "/Applications/McBopomofo.app/Contents/Resources/hook.sh",
            "NextUpdateCheckDate": Date(),
            "KeyboardLayout": 2,
        ]
        let result = LegacyMigration.preferencesToMigrate(legacy: legacy, current: [:])
        for key in LegacyMigration.keysNeverMigrated {
            XCTAssertNil(result[key], "\(key) must never be migrated")
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["KeyboardLayout"] as? Int, 2)
    }

    // MARK: - legacyUserDataFolder

    /// `URL.appendingPathComponent` appends a trailing slash when the path
    /// already exists as a directory, so two URLs naming the same folder
    /// are not `==`. Compare the paths.
    private func folderPath(_ source: LegacyMigration.LegacyUserDataSource) -> String? {
        guard case .folder(let url) = source else { return nil }
        return url.path
    }

    func testUsesCustomLegacyFolderWhenTheFlagIsOnAndItExists() throws {
        let custom = sandbox.appendingPathComponent("Dropbox-McBopomofo")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let fallback = sandbox.appendingPathComponent("McBopomofo")

        let resolved = LegacyMigration.legacyUserDataFolder(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": true, "CustomUserPhraseLocation": custom.path,
            ],
            defaultLegacyFolder: fallback)

        XCTAssertEqual(folderPath(resolved), custom.path)
    }

    func testReportsUnavailableWhenTheCustomLegacyFolderDoesNotExist() {
        let fallback = sandbox.appendingPathComponent("McBopomofo")
        let missing = sandbox.appendingPathComponent("gone").path
        let resolved = LegacyMigration.legacyUserDataFolder(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": true, "CustomUserPhraseLocation": missing,
            ],
            defaultLegacyFolder: fallback)
        // Not the default folder: an unmounted volume must read as "come
        // back later", not as "this user has no data".
        XCTAssertEqual(resolved, .customLocationUnavailable(missing))
    }

    func testFallsBackWhenTheCustomLocationFlagIsOff() throws {
        let custom = sandbox.appendingPathComponent("Dropbox-McBopomofo")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let fallback = sandbox.appendingPathComponent("McBopomofo")

        let resolved = LegacyMigration.legacyUserDataFolder(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": false, "CustomUserPhraseLocation": custom.path,
            ],
            defaultLegacyFolder: fallback)

        XCTAssertEqual(folderPath(resolved), fallback.path)
    }

    // MARK: - copyUserData

    func testCopiesLegacyFolderWhenTheNewOneIsAbsent() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        let legacyFile = legacyFolder.appendingPathComponent("data.txt")
        try "小麥 ㄒㄧㄠˇ-ㄇㄞˋ\n".write(to: legacyFile, atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        let copiedFile = newFolder.appendingPathComponent("data.txt")
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "小麥 ㄒㄧㄠˇ-ㄇㄞˋ\n")
        // The original must be left exactly as it was: the input method
        // this fork was renamed away from may still be installed.
        XCTAssertEqual(try String(contentsOf: legacyFile, encoding: .utf8), "小麥 ㄒㄧㄠˇ-ㄇㄞˋ\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: legacyFolder.path), ["data.txt"])
    }

    func testDoesNothingWhenThereIsNoLegacyFolder() {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    /// A legacy folder that is itself a symlink (the Dropbox setup) must
    /// produce a *real* new folder, not a second name for the same
    /// storage -- otherwise both input methods write the same files.
    func testLegacyFolderThatIsASymlinkProducesARealNewFolder() throws {
        let realStore = sandbox.appendingPathComponent("Dropbox-store")
        try FileManager.default.createDirectory(at: realStore, withIntermediateDirectories: true)
        let realFile = realStore.appendingPathComponent("latin-user.txt")
        try "acer 3\n".write(to: realFile, atomically: true, encoding: .utf8)

        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createSymbolicLink(at: legacyFolder, withDestinationURL: realStore)
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["latin-user.txt"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: newFolder.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        let copiedFile = newFolder.appendingPathComponent("latin-user.txt")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: copiedFile.path)[.type]
                as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "acer 3\n")

        // The symlink and the store behind it are both untouched.
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: legacyFolder.path)[.type]
                as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: legacyFolder.path),
            realStore.path)
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "acer 3\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: realStore.path),
            ["latin-user.txt"])
    }

    /// Same hazard one level down: a symlinked *file* inside the legacy
    /// folder must come out the other side as a real file.
    func testSymlinkedFileInsideTheLegacyFolderIsCopiedAsARealFile() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        let elsewhere = sandbox.appendingPathComponent("elsewhere.txt")
        try "synced\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: legacyFolder.appendingPathComponent("data.txt"), withDestinationURL: elsewhere)
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        let copiedFile = newFolder.appendingPathComponent("data.txt")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: copiedFile.path)[.type]
                as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "synced\n")
    }

    func testSubdirectoriesAreNotCopied() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(
            at: legacyFolder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "deep\n".write(
            to: legacyFolder.appendingPathComponent("nested/data.txt"), atomically: true,
            encoding: .utf8)
        try "flat\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: newFolder.path), ["data.txt"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("nested").path))
    }

    // MARK: - copyUserData, defensive paths

    func testRefusesWhenTheNewPathIsADanglingSymlink() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try "legacy\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        let nowhere = sandbox.appendingPathComponent("nowhere")
        try FileManager.default.createSymbolicLink(at: newFolder, withDestinationURL: nowhere)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .failed(.destinationBlocked(path: newFolder.path)))
        // Still a symlink, still dangling: nothing was written through it.
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: newFolder.path)[.type]
                as? FileAttributeType, .typeSymbolicLink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nowhere.path))
    }

    func testCopiesIntoAnExistingEmptyDirectory() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try "legacy\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "legacy\n")
    }

    func testFailsAndLeavesNoNewFolderWhenTheLegacyFolderCannotBeRead() throws {
        try XCTSkipIf(getuid() == 0, "chmod 000 does not deny root")
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try "legacy\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: legacyFolder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: legacyFolder.path)
        }
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(
            outcome,
            .failed(.legacyFolderUnreadable(path: legacyFolder.resolvingSymlinksInPath().path)))
        // No new folder: the source is listed before the destination is
        // created, so an unreadable source costs nothing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    // MARK: - legacyUserDataFolder, remaining cases

    func testReportsUnavailableWhenTheCustomLegacyPathIsAFile() throws {
        let file = sandbox.appendingPathComponent("not-a-folder.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        let fallback = sandbox.appendingPathComponent("McBopomofo")

        let resolved = LegacyMigration.legacyUserDataFolder(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": true, "CustomUserPhraseLocation": file.path,
            ],
            defaultLegacyFolder: fallback)

        XCTAssertEqual(resolved, .customLocationUnavailable(file.path))
    }

    func testFallsBackWhenTheCustomLegacyPathIsAnEmptyString() {
        let fallback = sandbox.appendingPathComponent("McBopomofo")
        let resolved = LegacyMigration.legacyUserDataFolder(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": true, "CustomUserPhraseLocation": "",
            ],
            defaultLegacyFolder: fallback)
        XCTAssertEqual(folderPath(resolved), fallback.path)
    }

    // MARK: - run, the marker rules

    /// Makes a legacy folder holding one file, and returns
    /// (legacyDefaultFolder, newFolder).
    private func makeLegacyFolder(contents: String = "legacy\n") throws -> (URL, URL) {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try contents.write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        return (legacyFolder, sandbox.appendingPathComponent("Bopomix"))
    }

    func testRunSetsBothMarkersWhenTheCopySucceeds() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()

        let result = LegacyMigration.run(
            legacyPreferences: ["KeyboardLayout": 2], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)

        XCTAssertEqual(result.userDataOutcome, .copied(changed: ["data.txt"]))
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertTrue(result.setUserDataMarker)
        XCTAssertEqual(result.preferencesToWrite["KeyboardLayout"] as? Int, 2)
    }

    func testRunSetsBothMarkersWhenThereIsNothingToCopy() {
        let result = LegacyMigration.run(
            legacyPreferences: [:], currentPreferences: [:],
            legacyDefaultFolder: sandbox.appendingPathComponent("McBopomofo"),
            newFolder: sandbox.appendingPathComponent("Bopomix"),
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)

        XCTAssertEqual(result.userDataOutcome, .notNeeded)
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertTrue(result.setUserDataMarker)
    }

    /// The blocking case: a failed copy must leave the user-data marker
    /// unset so the next launch retries, while the preference half -- which
    /// did succeed -- is recorded.
    func testRunWithholdsTheUserDataMarkerWhenTheCopyFails() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()
        try FileManager.default.createSymbolicLink(
            at: newFolder, withDestinationURL: sandbox.appendingPathComponent("nowhere"))

        let result = LegacyMigration.run(
            legacyPreferences: ["KeyboardLayout": 2], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)

        XCTAssertEqual(
            result.userDataOutcome, .failed(.destinationBlocked(path: newFolder.path)))
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertFalse(result.setUserDataMarker)
    }

    func testRunWithholdsTheUserDataMarkerWhenTheCustomLocationIsUnavailable() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()
        let missing = sandbox.appendingPathComponent("unmounted-volume").path

        let result = LegacyMigration.run(
            legacyPreferences: [
                "UseCustomUserPhraseLocation": true, "CustomUserPhraseLocation": missing,
            ],
            currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)

        XCTAssertEqual(result.userDataOutcome, .customLocationUnavailable(missing))
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertFalse(result.setUserDataMarker)
        // Crucially it did *not* quietly copy the default legacy folder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    func testRunLeavesTheFoldersAloneOnceTheUserDataMarkerIsSet() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()

        let result = LegacyMigration.run(
            legacyPreferences: ["KeyboardLayout": 2], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: true)

        XCTAssertEqual(result.userDataOutcome, .skipped("user data marker already set"))
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertFalse(result.setUserDataMarker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: legacyFolder.path), ["data.txt"])
    }

    func testRunSkipsThePreferenceHalfOnceItsMarkerIsSet() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()

        let result = LegacyMigration.run(
            legacyPreferences: ["KeyboardLayout": 2], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: true, userDataAlreadyMigrated: false)

        XCTAssertTrue(result.preferencesToWrite.isEmpty)
        XCTAssertFalse(result.setPrefsMarker)
        XCTAssertEqual(result.userDataOutcome, .copied(changed: ["data.txt"]))
        XCTAssertTrue(result.setUserDataMarker)
    }

    // MARK: - AddPhraseHookPath, filtered on its value

    func testDropsAddPhraseHookPathPointingIntoTheLegacyBundle() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: [
                "AddPhraseHookPath":
                    "/Library/Input Methods/McBopomofo.app/Contents/Resources/add-phrase-hook.sh"
            ],
            current: [:])
        XCTAssertNil(result["AddPhraseHookPath"])
    }

    func testMigratesAnAddPhraseHookPathTheUserChose() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["AddPhraseHookPath": "/Users/someone/bin/commit-phrase.sh"], current: [:])
        XCTAssertEqual(
            result["AddPhraseHookPath"] as? String, "/Users/someone/bin/commit-phrase.sh")
    }

    // MARK: - copyUserData, per-file merge

    func testCopiesFilesTheNewFolderIsMissingEvenWhenOthersAreThere() throws {
        let (legacyFolder, newFolder) = try makeLegacyFolder()
        try "acer 3\n".write(
            to: legacyFolder.appendingPathComponent("latin-user.txt"), atomically: true,
            encoding: .utf8)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "mine ㄨㄛˇ\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt", "latin-user.txt"]))
        // The user's own line stays first and keeps its place; the legacy
        // line joins it; the file the new folder lacked arrives whole.
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "mine ㄨㄛˇ\nlegacy\n")
        XCTAssertEqual(
            try String(
                contentsOf: newFolder.appendingPathComponent("latin-user.txt"), encoding: .utf8),
            "acer 3\n")
    }

    func testReportsNotNeededWhenTheLegacyFolderHoldsNoRegularFiles() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createDirectory(
            at: legacyFolder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    func testFailsWhenTheLegacyFolderIsASymlinkToAMissingTarget() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        try FileManager.default.createSymbolicLink(
            at: legacyFolder, withDestinationURL: sandbox.appendingPathComponent("unmounted"))
        let newFolder = sandbox.appendingPathComponent("Bopomix")

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        // Retryable: the data exists, the volume is just not mounted.
        XCTAssertEqual(
            outcome, .failed(.legacySymlinkTargetMissing(path: legacyFolder.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFolder.path))
    }

    // MARK: - userNoticeReason

    func testTellsTheUserOnlyAboutRetryableOutcomes() {
        XCTAssertEqual(
            LegacyMigration.userNoticeReason(for: .failed(.destinationBlocked(path: "/x"))),
            .destinationBlocked(path: "/x"))
        XCTAssertEqual(
            LegacyMigration.userNoticeReason(for: .customLocationUnavailable("/Volumes/x")),
            .customLocationUnavailable(path: "/Volumes/x"))
        XCTAssertEqual(
            LegacyMigration.userNoticeReason(
                for: .partial(
                    changed: ["data.txt"],
                    skipped: [LegacyMigration.SkippedFile(name: "bad.txt", reason: "not UTF-8")],
                    legacyFolderPath: "/old")),
            .partial(skippedNames: ["bad.txt"], legacyFolderPath: "/old"))
        XCTAssertNil(LegacyMigration.userNoticeReason(for: .copied(changed: ["data.txt"])))
        XCTAssertNil(LegacyMigration.userNoticeReason(for: .notNeeded))
        XCTAssertNil(LegacyMigration.userNoticeReason(for: .skipped("already")))
    }

    // MARK: - AddPhraseHookPath, component-wise

    func testDropsAddPhraseHookPathWhateverTheBundleIsSpelledLike() {
        for path in [
            "/Library/Input Methods/McBopomofo.app/Contents/Resources/add-phrase-hook.sh",
            "/Library/Input Methods/mcbopomofo.app/Contents/Resources/add-phrase-hook.sh",
        ] {
            let result = LegacyMigration.preferencesToMigrate(
                legacy: ["AddPhraseHookPath": path], current: [:])
            XCTAssertNil(result["AddPhraseHookPath"], path)
        }
    }

    func testKeepsAPathMerelyNamedLikeTheLegacyBundle() {
        let path = "/Users/someone/McBopomofo.app-scripts/hook.sh"
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["AddPhraseHookPath": path], current: [:])
        XCTAssertEqual(result["AddPhraseHookPath"] as? String, path)
    }

    func testDropsAnAddPhraseHookPathThatIsNotAString() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["AddPhraseHookPath": 42], current: [:])
        XCTAssertNil(result["AddPhraseHookPath"])
    }

    // MARK: - copyUserData, line-by-line merge

    /// The blocking case. A first attempt stood down (unmounted custom
    /// location), the user opened the dictionary, found it empty and typed
    /// a phrase in by hand -- so `data.txt` now holds this app's template
    /// header *and* one line of theirs. Keeping the file whole would have
    /// thrown away the entire legacy phrase list; overwriting it would
    /// have thrown away the line they just typed.
    func testAppendsOnlyTheLegacyLinesTheDestinationIsMissing() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "# legacy header\n甲 ㄐㄧㄚˇ\n乙 ㄧˇ\n丙 ㄅㄧㄥˇ\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "# Custom Phrases or Characters.\n#\n乙 ㄧˇ\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        // The destination's own header and its line stay first and intact;
        // only the two missing lines are appended, in legacy order; the
        // legacy header is not carried over.
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "# Custom Phrases or Characters.\n#\n乙 ㄧˇ\n甲 ㄐㄧㄚˇ\n丙 ㄅㄧㄥˇ\n")
    }

    func testAddsATrailingNewlineBeforeAppendingWhenTheDestinationLacksOne() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "甲 ㄐㄧㄚˇ\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "乙 ㄧˇ".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        _ = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "乙 ㄧˇ\n甲 ㄐㄧㄚˇ\n")
    }

    func testMatchesCRLFLegacyLinesAgainstLFDestinationLines() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "甲 ㄐㄧㄚˇ\r\n乙 ㄧˇ\r\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "甲 ㄐㄧㄚˇ\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        // 甲 matched despite the CR, and 乙 arrives without a \r tail.
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "甲 ㄐㄧㄚˇ\n乙 ㄧˇ\n")
    }

    /// latin-user.txt is `word` or `word\tcount`, and the engine keys on
    /// the lowercased word alone. Two lines for one word with different
    /// counts is exactly what its own merge exists to prevent.
    func testDeduplicatesLatinUserWordsByWordNotByWholeLine() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "acer\t9\nAcer\t4\ngmail\t2\n".write(
            to: legacyFolder.appendingPathComponent("latin-user.txt"), atomically: true,
            encoding: .utf8)
        try "acer\t3\n".write(
            to: newFolder.appendingPathComponent("latin-user.txt"), atomically: true,
            encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["latin-user.txt"]))
        // "Acer" is the same word as "acer", so no second row is added --
        // the existing row is raised to the larger count instead, because
        // the engine sums duplicate rows. gmail is new.
        XCTAssertEqual(
            try String(
                contentsOf: newFolder.appendingPathComponent("latin-user.txt"), encoding: .utf8),
            "acer\t9\ngmail\t2\n")
    }

    func testSkipsAFileThatIsNotValidUTF8AndKeepsGoing() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0x01]).write(
            to: legacyFolder.appendingPathComponent("bad.txt"))
        try "甲 ㄐㄧㄚˇ\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        // Real content, not just a header: a header-only destination is a
        // placeholder and would be replaced byte for byte, encoding and
        // all, which is a different path (see the placeholder tests).
        try "# header\n丙 ㄅㄧㄥˇ\n".write(
            to: newFolder.appendingPathComponent("bad.txt"), atomically: true, encoding: .utf8)
        try "# header\n乙 ㄧˇ\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(
            outcome,
            .partial(
                changed: ["data.txt"],
                skipped: [LegacyMigration.SkippedFile(name: "bad.txt", reason: "not valid UTF-8")]))
        // The good file was still merged, and the unreadable one untouched.
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "# header\n乙 ㄧˇ\n甲 ㄐㄧㄚˇ\n")
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("bad.txt"), encoding: .utf8),
            "# header\n丙 ㄅㄧㄥˇ\n")
    }

    func testSkipsWhenTheDestinationFileIsASymlink() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "甲 ㄐㄧㄚˇ\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let elsewhere = sandbox.appendingPathComponent("elsewhere.txt")
        try "somewhere else\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: newFolder.appendingPathComponent("data.txt"), withDestinationURL: elsewhere)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(
            outcome,
            .partial(
                changed: [],
                skipped: [
                    LegacyMigration.SkippedFile(
                        name: "data.txt", reason: "destination is not a regular file")
                ]))
        // Nothing was written through the link.
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "somewhere else\n")
    }

    /// The retry a `.partial` or `.failed` result asks for must not
    /// duplicate what an earlier attempt already merged.
    func testMergingTwiceChangesNothingTheSecondTime() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "甲 ㄐㄧㄚˇ\n乙 ㄧˇ\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "# header\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            LegacyMigration.copyUserData(from: legacyFolder, to: newFolder),
            .copied(changed: ["data.txt"]))
        let afterFirst = try String(
            contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8)

        XCTAssertEqual(
            LegacyMigration.copyUserData(from: legacyFolder, to: newFolder), .notNeeded)
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            afterFirst)
    }

    // MARK: - mergedText

    func testNeverCarriesBlankOrCommentLines() {
        let merged = LegacyMigration.mergedText(
            legacy: "# legacy header\n\n   \n甲 ㄐㄧㄚˇ\n", existing: "", isLatinUserWordList: false)
        XCTAssertEqual(merged, "甲 ㄐㄧㄚˇ\n")
    }

    func testDoesNotRepeatALegacyLineThatAppearsTwice() {
        let merged = LegacyMigration.mergedText(
            legacy: "甲 ㄐㄧㄚˇ\n甲 ㄐㄧㄚˇ\n", existing: "", isLatinUserWordList: false)
        XCTAssertEqual(merged, "甲 ㄐㄧㄚˇ\n")
    }

    func testReportsNoChangeWhenEveryLegacyLineIsAlreadyThere() {
        XCTAssertNil(
            LegacyMigration.mergedText(
                legacy: "甲 ㄐㄧㄚˇ\n", existing: "# header\n甲 ㄐㄧㄚˇ\n",
                isLatinUserWordList: false))
    }

    /// U+2028 and friends are newlines to Swift but not to the engine's
    /// `std::getline(…, '\n')`, so a record containing one stays one
    /// record.
    func testDoesNotBreakLinesTheEngineWouldKeepWhole() {
        XCTAssertEqual(LegacyMigration.splitLines("a\u{2028}b\nc"), ["a\u{2028}b", "c"])
        XCTAssertEqual(LegacyMigration.splitLines("a\r\nb\n"), ["a", "b", ""])
    }

    // MARK: - latin-user.txt counts

    func testRaisesAnExistingCountToTheLegacyOne() {
        let merged = LegacyMigration.mergedText(
            legacy: "acer\t9\n", existing: "acer\t3\n", isLatinUserWordList: true)
        XCTAssertEqual(merged, "acer\t9\n")
    }

    func testLeavesAHigherOrEqualExistingCountAlone() {
        XCTAssertNil(
            LegacyMigration.mergedText(
                legacy: "acer\t2\n", existing: "acer\t3\n", isLatinUserWordList: true))
        XCTAssertNil(
            LegacyMigration.mergedText(
                legacy: "acer\t3\n", existing: "acer\t3\n", isLatinUserWordList: true))
    }

    /// A count raise must converge, or a `.partial` retry would keep
    /// climbing -- which is exactly what appending a second row would do,
    /// since the engine sums duplicates.
    func testRaisingACountIsIdempotent() {
        let once = LegacyMigration.mergedText(
            legacy: "acer\t9\n", existing: "acer\t3\n", isLatinUserWordList: true)
        XCTAssertEqual(once, "acer\t9\n")
        XCTAssertNil(
            LegacyMigration.mergedText(
                legacy: "acer\t9\n", existing: once!, isLatinUserWordList: true))
    }

    func testCountsDuplicateDestinationRowsTheWayTheEngineWill() {
        // The engine sums 2 + 2 = 4, so a legacy count of 3 adds nothing.
        XCTAssertNil(
            LegacyMigration.mergedText(
                legacy: "acer\t3\n", existing: "acer\t2\nacer\t2\n",
                isLatinUserWordList: true))
    }

    // MARK: - run, .partial

    func testRunWithholdsTheUserDataMarkerOnAPartialMerge() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data([0xff, 0xfe]).write(to: legacyFolder.appendingPathComponent("bad.txt"))
        try "# header\n丙 ㄅㄧㄥˇ\n".write(
            to: newFolder.appendingPathComponent("bad.txt"), atomically: true, encoding: .utf8)

        let result = LegacyMigration.run(
            legacyPreferences: [:], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)

        XCTAssertEqual(
            result.userDataOutcome,
            .partial(
                changed: [],
                skipped: [LegacyMigration.SkippedFile(name: "bad.txt", reason: "not valid UTF-8")],
                legacyFolderPath: legacyFolder.path))
        XCTAssertTrue(result.setPrefsMarker)
        XCTAssertFalse(result.setUserDataMarker)
        XCTAssertNotNil(LegacyMigration.userNoticeReason(for: result.userDataOutcome))
    }

    // MARK: - AddPhraseHookPath, normalized

    func testDropsAnAddPhraseHookPathThatIsBlank() {
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["AddPhraseHookPath": "   \n"], current: [:])
        XCTAssertNil(result["AddPhraseHookPath"])
    }

    func testKeepsAPathThatOnlyTraversesThroughTheLegacyBundle() {
        // Standardized, `/a/McBopomofo.app/../b/hook.sh` is `/a/b/hook.sh`
        // and has nothing to do with the other app's bundle.
        let path = "/a/McBopomofo.app/../b/hook.sh"
        let result = LegacyMigration.preferencesToMigrate(
            legacy: ["AddPhraseHookPath": path], current: [:])
        XCTAssertEqual(result["AddPhraseHookPath"] as? String, path)
    }

    // MARK: - placeholder destinations and recovery

    /// A destination holding nothing but this app's comment header is a
    /// placeholder, so it is replaced byte for byte -- which is the only
    /// way a legacy file in some other encoding ever arrives.
    func testReplacesAHeaderOnlyDestinationWithTheLegacyBytesWhateverTheEncoding() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        // Big5 bytes for 小麥, which is not valid UTF-8.
        let big5 = Data([0xa4, 0x70, 0xbb, 0xf3, 0x0a])
        try big5.write(to: legacyFolder.appendingPathComponent("data.txt"))
        try "# Custom Phrases or Characters.\n#\n\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .copied(changed: ["data.txt"]))
        XCTAssertEqual(
            try Data(contentsOf: newFolder.appendingPathComponent("data.txt")), big5)
    }

    /// ...and the second pass sees identical bytes and stands down, rather
    /// than failing to decode them and reporting a skip for ever.
    func testAHeaderOnlyReplacementConvergesOnTheNextRun() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data([0xa4, 0x70, 0xbb, 0xf3, 0x0a]).write(
            to: legacyFolder.appendingPathComponent("data.txt"))
        try "# header\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            LegacyMigration.copyUserData(from: legacyFolder, to: newFolder),
            .copied(changed: ["data.txt"]))
        XCTAssertEqual(
            LegacyMigration.copyUserData(from: legacyFolder, to: newFolder), .notNeeded)
    }

    /// A file that could not be read one run and can be the next must
    /// finish the job and set the marker.
    func testRunRecoversOnceTheUnreadableFileBecomesReadable() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let legacyFile = legacyFolder.appendingPathComponent("data.txt")
        try Data([0xff, 0xfe]).write(to: legacyFile)
        // A destination with real content, so the placeholder path above
        // does not apply and the bad encoding really is a skip.
        try "# header\n乙 ㄧˇ\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let first = LegacyMigration.run(
            legacyPreferences: [:], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: false, userDataAlreadyMigrated: false)
        XCTAssertFalse(first.setUserDataMarker)

        try "甲 ㄐㄧㄚˇ\n".write(to: legacyFile, atomically: true, encoding: .utf8)

        let second = LegacyMigration.run(
            legacyPreferences: [:], currentPreferences: [:],
            legacyDefaultFolder: legacyFolder, newFolder: newFolder,
            prefsAlreadyMigrated: true, userDataAlreadyMigrated: false)
        XCTAssertEqual(second.userDataOutcome, .copied(changed: ["data.txt"]))
        XCTAssertTrue(second.setUserDataMarker)
        XCTAssertNil(LegacyMigration.userNoticeReason(for: second.userDataOutcome))
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "# header\n乙 ㄧˇ\n甲 ㄐㄧㄚˇ\n")
    }
}
