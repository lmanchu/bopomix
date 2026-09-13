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

        XCTAssertEqual(outcome, .copied)
        let copiedFile = newFolder.appendingPathComponent("data.txt")
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "小麥 ㄒㄧㄠˇ-ㄇㄞˋ\n")
        // The original must be left exactly as it was: the input method
        // this fork was renamed away from may still be installed.
        XCTAssertEqual(try String(contentsOf: legacyFile, encoding: .utf8), "小麥 ㄒㄧㄠˇ-ㄇㄞˋ\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: legacyFolder.path), ["data.txt"])
    }

    func testDoesNothingWhenTheNewFolderAlreadyExists() throws {
        let legacyFolder = sandbox.appendingPathComponent("McBopomofo")
        let newFolder = sandbox.appendingPathComponent("Bopomix")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try "legacy\n".write(
            to: legacyFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try "mine\n".write(
            to: newFolder.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let outcome = LegacyMigration.copyUserData(from: legacyFolder, to: newFolder)

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "mine\n")
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

        XCTAssertEqual(outcome, .copied)
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

        XCTAssertEqual(outcome, .copied)
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

        XCTAssertEqual(outcome, .copied)
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

        XCTAssertEqual(outcome, .failed)
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

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(
            try String(contentsOf: newFolder.appendingPathComponent("data.txt"), encoding: .utf8),
            "legacy\n")
    }

    func testFailsAndLeavesNoNewFolderWhenTheLegacyFolderCannotBeRead() throws {
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

        XCTAssertEqual(outcome, .failed)
        // The empty folder a failed attempt used to leave behind is what
        // made every later attempt report "already has data".
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

        XCTAssertEqual(result.userDataOutcome, .copied)
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

        XCTAssertEqual(result.userDataOutcome, .failed)
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
        XCTAssertEqual(result.userDataOutcome, .copied)
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
}
