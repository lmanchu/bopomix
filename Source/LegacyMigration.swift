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
/// once.
///
/// Split into a pure core (`run`, and the three functions it composes) and
/// a thin `UserDefaults` wrapper (`migrateIfNeeded`) so that the marker
/// logic -- which decides whether the migration is allowed to consider
/// itself done -- is testable against a temporary directory instead of the
/// live domain.
///
/// Deliberately non-destructive in both directions:
///
///  * the legacy domain and the legacy folder are only ever *read* -- the
///    original McBopomofo may still be installed and in use, and this
///    must not disturb it; and
///  * nothing already present under the new identity is overwritten --
///    preferences are only filled in where the new domain has no value,
///    and the folder copy stands down as soon as the new folder has
///    anything in it.
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

    /// Set once the preference half has been written.
    static let prefsMarkerKey = "LegacyMcBopomofoPrefsMigrated"

    /// Set once the user-data half has *succeeded* -- meaning the folder
    /// was copied, or there was demonstrably nothing to copy.
    ///
    /// Two markers rather than one because the halves fail independently.
    /// The preference copy is a dictionary merge that cannot really fail;
    /// the folder copy depends on a volume being mounted and a directory
    /// being readable. Sharing one marker meant a single transient
    /// failure -- an unmounted Dropbox at first launch, say -- recorded
    /// the whole migration as done and the user's dictionary never
    /// arrived, on that launch or any later one.
    static let userDataMarkerKey = "LegacyMcBopomofoUserDataMigrated"

    /// The key whose value decides whether it may be migrated; see
    /// `shouldMigrate(key:value:)`.
    static let addPhraseHookPathKey = "AddPhraseHookPath"

    /// A path containing this component lives inside the other app's
    /// bundle, which may be uninstalled at any time.
    static let legacyBundlePathMarker = "McBopomofo.app/"

    /// Legacy keys that must not cross over even when the new domain has
    /// no value for them. Each is here for its own reason:
    ///
    ///  * the two markers -- copying them in would let a legacy domain
    ///    suppress the very migration that is meant to write them.
    ///  * `UseCustomUserPhraseLocation` / `CustomUserPhraseLocation` --
    ///    inheriting these would leave Bopomix and a still-installed
    ///    McBopomofo reading and writing *the same* user-phrase folder.
    ///    They do not write it the same way: McBopomofo's `_removePhrase`
    ///    rewrites the whole file, while Bopomix appends, so two live
    ///    input methods on one folder lose phrases to interleaving. The
    ///    folder is copied instead (see `legacyUserDataFolder`), which
    ///    gives the user their words without the shared-writer hazard.
    ///  * `NextUpdateCheckDate` -- machine state (when this install last
    ///    looked for an update), not a preference the user chose.
    ///
    /// `AddPhraseHookPath` is *not* here: it is filtered on its value
    /// instead, by `shouldMigrate(key:value:)`.
    static let keysNeverMigrated: Set<String> = [
        prefsMarkerKey,
        userDataMarkerKey,
        "UseCustomUserPhraseLocation",
        "CustomUserPhraseLocation",
        "NextUpdateCheckDate",
    ]

    /// What the folder half of the copy did.
    enum UserDataCopyOutcome: Equatable {
        /// Files were copied into a new (or previously empty) folder.
        case copied
        /// Nothing to do: no legacy folder, or the new one already holds
        /// the user's data.
        case notNeeded
        /// Something was in the way or the copy threw. The marker must not
        /// be set, so the next launch tries again.
        case failed
    }

    /// Where the legacy install's user data should be read from.
    enum LegacyUserDataSource: Equatable {
        case folder(URL)
        /// The legacy install pointed at a custom folder that is not
        /// there *right now* -- an unmounted volume, or a Dropbox folder
        /// still being materialised. Distinct from "no custom folder",
        /// because the right response is to wait, not to substitute the
        /// default folder and declare victory.
        case customLocationUnavailable(String)
    }

    /// The user-data half's result as `run` reports it.
    enum UserDataMigrationOutcome: Equatable {
        case copied
        case notNeeded
        case failed
        /// The marker was already set on entry.
        case skipped(String)
        case customLocationUnavailable(String)
    }

    /// What `run` decided; `migrateIfNeeded` applies it verbatim.
    struct MigrationResult {
        var preferencesToWrite: [String: Any]
        var userDataOutcome: UserDataMigrationOutcome
        var setPrefsMarker: Bool
        var setUserDataMarker: Bool
    }

    /// Whether one legacy key/value pair may be carried over.
    ///
    /// `AddPhraseHookPath` needs the value, not just the key: the stock
    /// value points at a script inside `McBopomofo.app`, which is a
    /// different bundle and may be uninstalled, so it has to go and let
    /// `populateDefaults()` fill in this app's own. But a user who pointed
    /// the hook at a script of their own would otherwise have it silently
    /// swapped for a different program on every phrase they add, while
    /// `AddPhraseHookEnabled` migrates and keeps the hook switched on. So
    /// only the in-bundle form is dropped.
    static func shouldMigrate(key: String, value: Any) -> Bool {
        if keysNeverMigrated.contains(key) {
            return false
        }
        if key == addPhraseHookPathKey {
            guard let path = value as? String else {
                return true
            }
            return !path.contains(legacyBundlePathMarker)
        }
        return true
    }

    /// The subset of `legacy` that should be written into the new domain:
    /// every key the new domain does not already have a value for, minus
    /// everything `shouldMigrate(key:value:)` rejects.
    ///
    /// Pure -- no defaults, no file system.
    static func preferencesToMigrate(legacy: [String: Any], current: [String: Any]) -> [String: Any]
    {
        var result: [String: Any] = [:]
        for (key, value) in legacy {
            if !shouldMigrate(key: key, value: value) {
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
    /// Reads the same two keys `LanguageModelManager +dataFolderPath` reads
    /// and, like it, does no tilde expansion and treats a relative path as
    /// relative to the working directory. It deliberately parts company on
    /// one case: `+dataFolderPath` returns the custom string
    /// unconditionally, missing or not, because its caller is about to
    /// create files there. Here a path that is not an existing directory
    /// means the user's data cannot be read *yet*, which is a reason to
    /// come back next launch rather than to fall through to the default
    /// folder -- that folder is stale or empty for such a user, and
    /// copying it would burn the one-shot marker on the wrong data.
    ///
    /// An empty string does fall back to the default folder: it is what
    /// `PreferencesModel` stores when the user clears the field, and it
    /// names no location at all.
    ///
    /// Reading the custom location matters for the user who had pointed
    /// McBopomofo at, say, a Dropbox folder: they still get a snapshot of
    /// their own words rather than an empty dictionary. It is only a
    /// snapshot -- Bopomix deliberately does not inherit the
    /// custom-location keys (see `keysNeverMigrated`), so anyone who wants
    /// the syncing folder back re-points it in Preferences, once,
    /// knowingly.
    static func legacyUserDataFolder(
        legacyPreferences: [String: Any], defaultLegacyFolder: URL,
        fileManager: FileManager = .default
    ) -> LegacyUserDataSource {
        guard legacyPreferences["UseCustomUserPhraseLocation"] as? Bool == true,
            let custom = legacyPreferences["CustomUserPhraseLocation"] as? String,
            !custom.isEmpty
        else {
            return .folder(defaultLegacyFolder)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: custom, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .customLocationUnavailable(custom)
        }
        return .folder(URL(fileURLWithPath: custom))
    }

    /// Copies the legacy user-data folder's top-level regular files to the
    /// new location.
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
    /// On failure the directory is removed again *if this call created
    /// it*, so a failed attempt does not leave an empty folder behind that
    /// would make every later attempt report `.notNeeded`. A directory
    /// that was already there is left exactly as found.
    static func copyUserData(
        from legacyFolder: URL, to newFolder: URL, fileManager: FileManager = .default
    ) -> UserDataCopyOutcome {
        let resolvedLegacy = legacyFolder.resolvingSymlinksInPath()
        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedLegacy.path, isDirectory: &legacyIsDirectory),
            legacyIsDirectory.boolValue
        else {
            // No legacy folder at all -- a fresh install rather than an
            // upgrade. Nothing to do, and nothing to retry.
            return .notNeeded
        }

        // Inspect the destination without following symlinks, so that a
        // link -- including one that dangles, which `fileExists` would
        // miss -- is seen for what it is.
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: newFolder.path)
        var createdDestination = false
        if let destinationAttributes {
            switch destinationAttributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                // Refuse: writing through it would put this app's data
                // wherever the link points, quite possibly back into the
                // folder McBopomofo is still using.
                NSLog(
                    "LegacyMigration: \(newFolder.path) is a symbolic link; not migrating user data"
                )
                return .failed
            case .typeDirectory:
                let existing = (try? fileManager.contentsOfDirectory(atPath: newFolder.path)) ?? []
                if !existing.isEmpty {
                    // The user already has data under the new identity.
                    return .notNeeded
                }
            // An empty directory is treated as if it were not there: it
            // is what a failed earlier attempt or a stray dev build
            // leaves, and it holds nothing worth protecting.
            default:
                NSLog("LegacyMigration: \(newFolder.path) is not a directory; not migrating user data")
                return .failed
            }
        }

        do {
            // Listed before the destination is created, so that an
            // unreadable source fails without leaving a new folder behind.
            let names = try fileManager.contentsOfDirectory(atPath: resolvedLegacy.path)
            if destinationAttributes == nil {
                try fileManager.createDirectory(at: newFolder, withIntermediateDirectories: true)
                createdDestination = true
            }
            for name in names {
                let source = resolvedLegacy.appendingPathComponent(name).resolvingSymlinksInPath()
                guard
                    let type = try? fileManager.attributesOfItem(atPath: source.path)[.type]
                        as? FileAttributeType, type == .typeRegular
                else {
                    continue
                }
                try fileManager.copyItem(at: source, to: newFolder.appendingPathComponent(name))
            }
            return .copied
        } catch {
            NSLog(
                "LegacyMigration: cannot copy \(resolvedLegacy.path) to \(newFolder.path): \(error.localizedDescription)"
            )
            if createdDestination {
                // Only ever removes a directory this call made, holding
                // only files this call just copied.
                try? fileManager.removeItem(at: newFolder)
            }
            return .failed
        }
    }

    /// The whole decision, as a pure function of its inputs and the file
    /// system it is handed.
    ///
    /// Returns what to write rather than writing it, so that the marker
    /// rules -- which is the part that can permanently lose a user's
    /// dictionary if it is wrong -- can be tested without a live domain.
    static func run(
        legacyPreferences: [String: Any],
        currentPreferences: [String: Any],
        legacyDefaultFolder: URL,
        newFolder: URL,
        prefsAlreadyMigrated: Bool,
        userDataAlreadyMigrated: Bool,
        fileManager: FileManager = .default
    ) -> MigrationResult {
        let preferences =
            prefsAlreadyMigrated
            ? [:]
            : preferencesToMigrate(legacy: legacyPreferences, current: currentPreferences)

        if userDataAlreadyMigrated {
            return MigrationResult(
                preferencesToWrite: preferences,
                userDataOutcome: .skipped("user data marker already set"),
                setPrefsMarker: !prefsAlreadyMigrated,
                setUserDataMarker: false)
        }

        switch legacyUserDataFolder(
            legacyPreferences: legacyPreferences, defaultLegacyFolder: legacyDefaultFolder,
            fileManager: fileManager)
        {
        case .customLocationUnavailable(let path):
            return MigrationResult(
                preferencesToWrite: preferences,
                userDataOutcome: .customLocationUnavailable(path),
                setPrefsMarker: !prefsAlreadyMigrated,
                setUserDataMarker: false)
        case .folder(let folder):
            let outcome = copyUserData(from: folder, to: newFolder, fileManager: fileManager)
            switch outcome {
            case .copied:
                return MigrationResult(
                    preferencesToWrite: preferences, userDataOutcome: .copied,
                    setPrefsMarker: !prefsAlreadyMigrated, setUserDataMarker: true)
            case .notNeeded:
                return MigrationResult(
                    preferencesToWrite: preferences, userDataOutcome: .notNeeded,
                    setPrefsMarker: !prefsAlreadyMigrated, setUserDataMarker: true)
            case .failed:
                return MigrationResult(
                    preferencesToWrite: preferences, userDataOutcome: .failed,
                    setPrefsMarker: !prefsAlreadyMigrated, setUserDataMarker: false)
            }
        }
    }

    /// Reads the two domains and the two markers, calls `run`, applies what
    /// it returned. Deliberately holds no logic of its own.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        let prefsDone = defaults.bool(forKey: prefsMarkerKey)
        let userDataDone = defaults.bool(forKey: userDataMarkerKey)
        if prefsDone && userDataDone {
            return
        }

        guard
            let appSupportPath = NSSearchPathForDirectoriesInDomains(
                .applicationSupportDirectory, .userDomainMask, true
            ).first
        else {
            NSLog("LegacyMigration: no Application Support directory; not migrating")
            return
        }

        let result = run(
            legacyPreferences: defaults.persistentDomain(forName: legacyDomain) ?? [:],
            currentPreferences: defaults.persistentDomain(
                forName: Bundle.main.bundleIdentifier ?? "") ?? [:],
            legacyDefaultFolder: URL(fileURLWithPath: appSupportPath).appendingPathComponent(
                legacyFolderName),
            newFolder: URL(fileURLWithPath: UserPhraseLocationHelper.defaultUserPhraseLocation),
            prefsAlreadyMigrated: prefsDone,
            userDataAlreadyMigrated: userDataDone)

        for (key, value) in result.preferencesToWrite {
            defaults.set(value, forKey: key)
        }
        if result.setPrefsMarker {
            defaults.set(true, forKey: prefsMarkerKey)
        }
        if result.setUserDataMarker {
            defaults.set(true, forKey: userDataMarkerKey)
        }

        NSLog(
            "LegacyMigration: migrated \(result.preferencesToWrite.count) preference key(s) from \(legacyDomain); user data: \(result.userDataOutcome)"
        )
    }
}
