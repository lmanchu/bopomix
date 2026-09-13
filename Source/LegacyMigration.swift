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

import Foundation

/// One-shot import of the settings and user data of the upstream
/// McBopomofo this fork was renamed away from.
///
/// The rename changed the bundle identifier, and macOS keys both the
/// preferences domain and (by convention) the Application Support folder
/// off the product name. To someone upgrading in place, that reads as
/// "my dictionary and all my settings are gone." This copies both across
/// once, on the first launch that finds no marker.
///
/// Deliberately non-destructive in both directions:
///
///  * the legacy domain and the legacy folder are only ever *read* -- the
///    original McBopomofo may still be installed and in use, and this
///    must not disturb it; and
///  * nothing already present under the new identity is overwritten --
///    preferences are only filled in where the new domain has no value,
///    and the folder copy is skipped entirely once the new folder exists.
///
/// Never runs under XCTest: `main.swift` gates the call on
/// `Preferences.isRunningUnderXCTest`, for the same reason
/// `populateDefaults()` is gated there.
enum LegacyMigration {
    /// The upstream McBopomofo preferences domain.
    static let legacyDomain = "org.openvanilla.inputmethod.McBopomofo"

    /// The upstream folder under `~/Library/Application Support`.
    static let legacyFolderName = "McBopomofo"

    /// Written into the *new* domain once the migration has run. Never
    /// copied out of the legacy domain, so a legacy domain that somehow
    /// carries this key cannot suppress the migration.
    static let markerKey = "LegacyMcBopomofoMigrationDone"

    /// The subset of `legacy` that should be written into the new domain:
    /// every key the new domain does not already have a value for, minus
    /// the marker key itself.
    ///
    /// Pure -- no defaults, no file system -- so it is directly testable.
    static func preferencesToMigrate(legacy: [String: Any], current: [String: Any]) -> [String: Any]
    {
        var result: [String: Any] = [:]
        for (key, value) in legacy {
            if key == markerKey {
                continue
            }
            if current[key] != nil {
                continue
            }
            result[key] = value
        }
        return result
    }

    /// Copies the whole legacy user-data folder to the new location, if
    /// and only if the legacy folder exists and the new one does not.
    ///
    /// Copies rather than moves: the original McBopomofo, if still
    /// installed, keeps reading and writing the folder it always had.
    ///
    /// - Returns: whether a copy actually happened.
    static func copyUserData(from legacyFolder: URL, to newFolder: URL, fileManager: FileManager = .default) -> Bool
    {
        var legacyIsDirectory: ObjCBool = false
        let legacyExists = fileManager.fileExists(
            atPath: legacyFolder.path, isDirectory: &legacyIsDirectory)
        guard legacyExists, legacyIsDirectory.boolValue else {
            return false
        }
        if fileManager.fileExists(atPath: newFolder.path) {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: newFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: legacyFolder, to: newFolder)
            return true
        } catch {
            NSLog(
                "LegacyMigration: cannot copy \(legacyFolder.path) to \(newFolder.path): \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Runs both halves of the migration once per user, then records that
    /// it has run.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: markerKey) {
            return
        }

        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let toMigrate = preferencesToMigrate(legacy: legacy, current: current)
        for (key, value) in toMigrate {
            defaults.set(value, forKey: key)
        }

        let appSupportPaths = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true)
        var copiedFolder = false
        if let appSupportPath = appSupportPaths.first {
            let legacyFolder = URL(fileURLWithPath: appSupportPath)
                .appendingPathComponent(legacyFolderName)
            let newFolder = URL(
                fileURLWithPath: UserPhraseLocationHelper.defaultUserPhraseLocation)
            copiedFolder = copyUserData(from: legacyFolder, to: newFolder)
        }

        defaults.set(true, forKey: markerKey)
        NSLog(
            "LegacyMigration: migrated \(toMigrate.count) preference key(s) from \(legacyDomain); user data folder copied: \(copiedFolder)"
        )
    }
}
