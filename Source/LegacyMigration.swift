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

    /// The upstream folder under `~/Library/Application Support`, used when
    /// the legacy install was not pointed at a custom location.
    static let legacyFolderName = "McBopomofo"

    /// Written into the *new* domain once the migration has run. Never
    /// copied out of the legacy domain, so a legacy domain that somehow
    /// carries this key cannot suppress the migration.
    static let markerKey = "LegacyMcBopomofoMigrationDone"

    /// Legacy keys that must not cross over even when the new domain has
    /// no value for them. Each is here for its own reason:
    ///
    ///  * `LegacyMcBopomofoMigrationDone` -- the marker itself. Copying it
    ///    in would let a legacy domain suppress the very migration that
    ///    is meant to write it.
    ///  * `UseCustomUserPhraseLocation` / `CustomUserPhraseLocation` --
    ///    inheriting these would leave Bopomix and a still-installed
    ///    McBopomofo reading and writing *the same* user-phrase folder.
    ///    They do not write it the same way: McBopomofo's `_removePhrase`
    ///    rewrites the whole file, while Bopomix appends, so two live
    ///    input methods on one folder lose phrases to interleaving. The
    ///    folder is copied instead (see `legacyUserDataFolder`), which
    ///    gives the user their words without the shared-writer hazard.
    ///  * `AddPhraseHookPath` -- the legacy value points at a script
    ///    inside `McBopomofo.app`, which is a different bundle and may be
    ///    uninstalled at any time. Leaving it unset lets
    ///    `populateDefaults()` fill in this app's own correct default.
    ///  * `NextUpdateCheckDate` -- machine state (when this install last
    ///    looked for an update), not a preference the user chose.
    static let keysNeverMigrated: Set<String> = [
        markerKey,
        "UseCustomUserPhraseLocation",
        "CustomUserPhraseLocation",
        "AddPhraseHookPath",
        "NextUpdateCheckDate",
    ]

    /// The subset of `legacy` that should be written into the new domain:
    /// every key the new domain does not already have a value for, minus
    /// everything in `keysNeverMigrated`.
    ///
    /// Pure -- no defaults, no file system -- so it is directly testable.
    static func preferencesToMigrate(legacy: [String: Any], current: [String: Any]) -> [String: Any]
    {
        var result: [String: Any] = [:]
        for (key, value) in legacy {
            if keysNeverMigrated.contains(key) {
                continue
            }
            if current[key] != nil {
                continue
            }
            result[key] = value
        }
        return result
    }

    /// Where the legacy install actually kept its user phrases.
    ///
    /// Reads `UseCustomUserPhraseLocation` / `CustomUserPhraseLocation` the
    /// same way `LanguageModelManager +dataFolderPath` does -- flag first,
    /// then the raw string, with no tilde expansion, because that method
    /// does none either. Falls back to `defaultLegacyFolder` whenever the
    /// flag is off, the string is missing or empty, or the path is not an
    /// existing directory.
    ///
    /// Reading it matters for the user who had pointed McBopomofo at, say,
    /// a Dropbox folder: they still get a snapshot of their own words
    /// rather than an empty dictionary. It is only a snapshot -- Bopomix
    /// deliberately does not inherit the custom-location keys (see
    /// `keysNeverMigrated`), so anyone who wants the syncing folder back
    /// re-points it in Preferences, once, knowingly.
    ///
    /// Pure apart from the existence check, which is why `fileManager` is
    /// injectable.
    static func legacyUserDataFolder(
        legacyPreferences: [String: Any], defaultLegacyFolder: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard legacyPreferences["UseCustomUserPhraseLocation"] as? Bool == true,
            let custom = legacyPreferences["CustomUserPhraseLocation"] as? String,
            !custom.isEmpty
        else {
            return defaultLegacyFolder
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: custom, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return defaultLegacyFolder
        }
        return URL(fileURLWithPath: custom)
    }

    /// Copies the legacy user-data folder's top-level regular files to the
    /// new location, if and only if the legacy folder resolves to a real
    /// directory and nothing at all exists at the new path.
    ///
    /// Copies rather than moves: the original McBopomofo, if still
    /// installed, keeps reading and writing the folder it always had.
    ///
    /// Symlink-safe by construction, because the legacy folder is a place
    /// users point at their own sync setups. The source is resolved before
    /// it is read, each entry is resolved before it is copied, and the
    /// destination is always a real directory holding real files -- so a
    /// legacy folder that *is* a symlink into Dropbox cannot end up
    /// silently sharing storage with the new one, which would reintroduce
    /// the two-writers-one-folder problem `keysNeverMigrated` avoids.
    /// Subdirectories and anything that is not a regular file are skipped;
    /// the input method only ever keeps flat text files here.
    ///
    /// - Returns: whether the copy ran to completion.
    static func copyUserData(from legacyFolder: URL, to newFolder: URL, fileManager: FileManager = .default) -> Bool
    {
        let resolvedLegacy = legacyFolder.resolvingSymlinksInPath()
        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedLegacy.path, isDirectory: &legacyIsDirectory),
            legacyIsDirectory.boolValue
        else {
            return false
        }

        // Anything at the new path at all means hands off -- including a
        // symlink, and including one that dangles. `fileExists` follows
        // symlinks and so would miss a dangling one; `attributesOfItem`
        // does not follow, and catches it.
        if fileManager.fileExists(atPath: newFolder.path) {
            return false
        }
        if (try? fileManager.attributesOfItem(atPath: newFolder.path)) != nil {
            return false
        }

        do {
            try fileManager.createDirectory(at: newFolder, withIntermediateDirectories: true)
            for name in try fileManager.contentsOfDirectory(atPath: resolvedLegacy.path) {
                let source = resolvedLegacy.appendingPathComponent(name).resolvingSymlinksInPath()
                guard
                    let type = try? fileManager.attributesOfItem(atPath: source.path)[.type]
                        as? FileAttributeType, type == .typeRegular
                else {
                    continue
                }
                try fileManager.copyItem(at: source, to: newFolder.appendingPathComponent(name))
            }
            return true
        } catch {
            // Whatever was copied before the failure stays, and so does an
            // empty folder if nothing was: deleting under a path the user
            // may have put there is a worse outcome than a partial copy.
            NSLog(
                "LegacyMigration: cannot copy \(resolvedLegacy.path) to \(newFolder.path): \(error.localizedDescription)"
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
            let defaultLegacyFolder = URL(fileURLWithPath: appSupportPath)
                .appendingPathComponent(legacyFolderName)
            let legacyFolder = legacyUserDataFolder(
                legacyPreferences: legacy, defaultLegacyFolder: defaultLegacyFolder)
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
