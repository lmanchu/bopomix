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
///    and the user-data folder is merged a line at a time: a file the new
///    folder lacks is copied, one that holds nothing but this app's own
///    comment header is replaced wholesale, and one with real content in
///    it gains only the legacy lines it is missing, appended at the end.
///    Existing content, its order and its comment header are left alone.
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

    /// Remembers which legacy files the last attempt could not read, so
    /// the same complaint is not shown at every launch.
    ///
    /// Lives in the *new* domain only -- it is this app's own bookkeeping,
    /// never something to migrate, so it does not belong in
    /// `keysNeverMigrated` (that list filters what comes *out* of the
    /// legacy domain).
    static let skippedFilesKey = "LegacyMcBopomofoSkippedFiles"

    /// The key whose value decides whether it may be migrated; see
    /// `shouldMigrate(key:value:)`.
    static let addPhraseHookPathKey = "AddPhraseHookPath"

    /// A path with this as one of its components lives inside the other
    /// app's bundle, which may be uninstalled at any time.
    static let legacyBundleName = "McBopomofo.app"

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

    /// One legacy file that could not be merged, and why.
    struct SkippedFile: Equatable {
        var name: String
        /// Deliberately coarse: free text for a log line and for the
        /// notice's file list, not a case to branch on. Every reason leads
        /// to the same handling -- skip this file, keep going, retry next
        /// launch -- so nothing yet needs to tell them apart. Give it a
        /// type when something does.
        var reason: String
    }

    /// Something that stopped the user-data half outright, described well
    /// enough for `AppDelegate` to localize it.
    enum MigrationProblem: Equatable {
        case customLocationUnavailable(path: String)
        case destinationBlocked(path: String)
        case legacySymlinkTargetMissing(path: String)
        case legacyFolderUnreadable(path: String)
        case partial(skippedNames: [String], legacyFolderPath: String)
    }

    /// What the folder half of the copy did.
    enum UserDataCopyOutcome: Equatable {
        /// At least one file was created or gained lines, and nothing was
        /// skipped.
        case copied(changed: [String])
        /// Nothing to do and nothing wrong: no legacy folder, no regular
        /// files in it, or every legacy line is already present.
        case notNeeded
        /// Some files were merged, some could not be. Retryable -- the
        /// merge is idempotent, so a later attempt re-tries only what is
        /// still missing.
        case partial(changed: [String], skipped: [SkippedFile])
        /// Nothing could be attempted. Retryable.
        case failed(MigrationProblem)
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
        case copied(changed: [String])
        case notNeeded
        case partial(changed: [String], skipped: [SkippedFile], legacyFolderPath: String)
        case failed(MigrationProblem)
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
                // Not a path at all. Nothing sane to carry over, and
                // `populateDefaults()` will supply this app's own.
                return false
            }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return false
            }
            // Component-wise, so that a folder merely *named* like the old
            // bundle -- `~/McBopomofo.app-scripts/hook.sh` -- is kept.
            // Standardized first, so `/a/McBopomofo.app/../b/hook.sh` is
            // judged on where it actually points. Case-insensitively,
            // because HFS+/APFS default to it and the same bundle can be
            // spelled either way.
            return !URL(fileURLWithPath: trimmed).standardizedFileURL.pathComponents.contains {
                $0.caseInsensitiveCompare(legacyBundleName) == .orderedSame
            }
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

    /// The name the Latin lexicon keeps its learned words in.
    static let latinUserWordListName = "latin-user.txt"

    /// Splits text the way the engine reads these files: on `\n` only,
    /// with a trailing `\r` dropped from each line.
    ///
    /// Not on `Character.isNewline`, which also breaks at U+2028, U+000B
    /// and U+0085 -- the engine's `std::getline(…, '\n')` does not, so
    /// splitting there would cut a line the engine keeps whole. CRLF is
    /// folded first because Swift makes `\r\n` a single `Character` that
    /// is not equal to `"\n"`, so splitting on the literal would hand a
    /// CRLF file back as one long line.
    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            }
    }

    /// Whether a line carries a record rather than a comment or nothing.
    private static func isContentLine(_ trimmed: String) -> Bool {
        !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// One `latin-user.txt` row as the engine parses it: the text before
    /// the first *tab* is the word, lowercased; what follows is a count,
    /// defaulting to 1 and never below it. See `ParseUserWordLine` and
    /// `ToLowerAscii` in `latin_lexicon.cpp`.
    static func parseUserWord(_ line: String) -> (word: String, count: Int) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let word = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        var count = 1
        if parts.count > 1, let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            count = max(parsed, 1)
        }
        return (word, count)
    }

    /// The destination's text with the legacy file merged into it, or nil
    /// when there is nothing to change.
    ///
    /// Blank lines and `#` comments are never carried: the destination has
    /// its own header, written from this app's own template, and a merge
    /// that appended the other app's header every time would not be
    /// idempotent. Comparison is on the trimmed line, so a CRLF legacy
    /// file matches a LF destination instead of appending everything again
    /// with `\r` tails.
    ///
    /// `latin-user.txt` is the exception, twice over. Its records are
    /// `word` or `word\tcount`, and `LatinLexicon` keys on the lowercased
    /// word, so the whole line is the wrong identity -- two rows for one
    /// word is exactly what `persistUserWords` exists to prevent. Worse,
    /// `loadUserWordList` *sums* the counts of duplicate rows, so an
    /// appended second row would inflate the word's weight on every load,
    /// and again on every `.partial` retry. A word the destination already
    /// knows therefore has its existing row **rewritten** to the larger of
    /// the two counts, in place, rather than a row added. Rewriting is
    /// what makes the retry idempotent.
    ///
    /// The result is rebuilt line by line, so a CRLF destination comes
    /// back as LF. The engine strips `\r` when reading anyway, and this
    /// app only ever writes LF.
    ///
    /// Pure, so the merge rules are testable on strings alone.
    static func mergedText(legacy: String, existing: String, isLatinUserWordList: Bool) -> String? {
        var lines = splitLines(existing)
        if lines.last == "" {
            lines.removeLast()
        }
        var changed = false

        if isLatinUserWordList {
            // word -> (index of its row, the count the engine will see)
            var known: [String: (row: Int, count: Int)] = [:]
            for (row, raw) in lines.enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard isContentLine(trimmed) else { continue }
                let parsed = parseUserWord(trimmed)
                guard !parsed.word.isEmpty else { continue }
                if let seen = known[parsed.word] {
                    // Rows the destination already duplicates: the engine
                    // sums them, so that total is what we compare against.
                    known[parsed.word] = (seen.row, seen.count + parsed.count)
                } else {
                    known[parsed.word] = (row, parsed.count)
                }
            }
            for raw in splitLines(legacy) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard isContentLine(trimmed) else { continue }
                let parsed = parseUserWord(trimmed)
                guard !parsed.word.isEmpty else { continue }
                if let seen = known[parsed.word] {
                    guard parsed.count > seen.count else { continue }
                    lines[seen.row] = "\(parsed.word)\t\(parsed.count)"
                    known[parsed.word] = (seen.row, parsed.count)
                    changed = true
                } else {
                    lines.append("\(parsed.word)\t\(parsed.count)")
                    known[parsed.word] = (lines.count - 1, parsed.count)
                    changed = true
                }
            }
        } else {
            var seen = Set<String>()
            for raw in lines {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if isContentLine(trimmed) {
                    seen.insert(trimmed)
                }
            }
            for raw in splitLines(legacy) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard isContentLine(trimmed), !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                lines.append(trimmed)
                changed = true
            }
        }

        guard changed else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether text holds any record at all, as opposed to only the
    /// comment header this app writes into a fresh user file.
    static func hasContentLines(_ text: String) -> Bool {
        splitLines(text).contains { isContentLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Merges the legacy user-data folder into the new location, line by
    /// line.
    ///
    /// Copies rather than moves: the original McBopomofo, if still
    /// installed, keeps reading and writing the folder it always had.
    ///
    /// Line by line rather than file by file, because by the time this
    /// runs the destination is very often *both* the app's own template
    /// header *and* some words the user typed in themselves. That happens
    /// whenever the first attempt had to stand down -- an unmounted custom
    /// location, say -- and the user, finding an empty dictionary, added a
    /// phrase by hand: `LanguageModelManager` creates the folder and its
    /// five files the moment anything touches the dictionary. Treating
    /// such a file as "the user's, keep it whole" silently dropped their
    /// entire legacy phrase list; treating it as a placeholder to
    /// overwrite would have dropped the phrase they just typed. Appending
    /// the lines that are missing keeps both.
    ///
    /// The destination's existing content, its order and its comment
    /// header are never touched -- new lines only ever go on the end.
    /// Every write is atomic (`Data.write(options: .atomic)` lands through
    /// a sibling temp file and a rename), and each file is handled on its
    /// own, so a failure part-way through leaves earlier files correctly
    /// merged rather than needing a rollback. The merge is idempotent, so
    /// the retry that a `.partial` result asks for re-appends nothing.
    ///
    /// Symlink-safe by construction, because the legacy folder is a place
    /// users point at their own sync setups. The source is resolved before
    /// it is read and each entry is resolved before it is read, so a
    /// legacy folder that *is* a symlink into Dropbox cannot end up
    /// silently sharing storage with the new one, which would reintroduce
    /// the two-writers-one-folder problem `keysNeverMigrated` avoids.
    /// Subdirectories and anything that is not a regular file are skipped;
    /// the input method only ever keeps flat text files here.
    static func copyUserData(
        from legacyFolder: URL, to newFolder: URL, fileManager: FileManager = .default
    ) -> UserDataCopyOutcome {
        // Read the legacy path without following it, so a symlink can be
        // told apart from what it points at.
        guard let legacyAttributes = try? fileManager.attributesOfItem(atPath: legacyFolder.path)
        else {
            // Nothing there at all -- a fresh install rather than an
            // upgrade. Nothing to do, and nothing to retry.
            return .notNeeded
        }
        let resolvedLegacy = legacyFolder.resolvingSymlinksInPath()
        var legacyIsDirectory: ObjCBool = false
        let resolvedExists = fileManager.fileExists(
            atPath: resolvedLegacy.path, isDirectory: &legacyIsDirectory)
        if (legacyAttributes[.type] as? FileAttributeType) == .typeSymbolicLink, !resolvedExists {
            // A link to a volume that is not mounted yet. The data exists,
            // it is just out of reach: retry rather than record success.
            NSLog(
                "LegacyMigration: \(legacyFolder.path) is a symbolic link to a missing target; will retry"
            )
            return .failed(.legacySymlinkTargetMissing(path: legacyFolder.path))
        }
        guard resolvedExists, legacyIsDirectory.boolValue else {
            return .notNeeded
        }

        // Inspect the destination without following symlinks, so that a
        // link -- including one that dangles, which `fileExists` would
        // miss -- is seen for what it is.
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: newFolder.path)
        if let destinationAttributes {
            switch destinationAttributes[.type] as? FileAttributeType {
            case .typeDirectory:
                break
            default:
                // A symlink would put this app's data wherever it points,
                // quite possibly back into the folder McBopomofo is still
                // using; anything else is simply in the way.
                NSLog(
                    "LegacyMigration: \(newFolder.path) is not a directory; not migrating user data")
                return .failed(.destinationBlocked(path: newFolder.path))
            }
        }

        let sources: [(name: String, url: URL)]
        do {
            // Sorted, so a run that hits trouble part-way leaves the same
            // state every time rather than whatever order the file system
            // happened to enumerate in.
            sources = try fileManager.contentsOfDirectory(atPath: resolvedLegacy.path)
                .sorted()
                .map {
                    (
                        name: $0,
                        url: resolvedLegacy.appendingPathComponent($0).resolvingSymlinksInPath()
                    )
                }
                .filter { entry in
                    (try? fileManager.attributesOfItem(atPath: entry.url.path)[.type]
                        as? FileAttributeType) == .typeRegular
                }
        } catch {
            NSLog(
                "LegacyMigration: cannot read \(resolvedLegacy.path): \(error.localizedDescription)")
            return .failed(.legacyFolderUnreadable(path: resolvedLegacy.path))
        }
        if sources.isEmpty {
            return .notNeeded
        }

        if destinationAttributes == nil {
            do {
                try fileManager.createDirectory(at: newFolder, withIntermediateDirectories: true)
            } catch {
                NSLog(
                    "LegacyMigration: cannot create \(newFolder.path): \(error.localizedDescription)"
                )
                return .failed(.destinationBlocked(path: newFolder.path))
            }
        }

        var changed: [String] = []
        var skipped: [SkippedFile] = []

        for source in sources {
            let destination = newFolder.appendingPathComponent(source.name)
            let existingAttributes = try? fileManager.attributesOfItem(atPath: destination.path)

            if existingAttributes == nil {
                do {
                    let data = try Data(contentsOf: source.url)
                    try data.write(to: destination, options: .atomic)
                    changed.append(source.name)
                } catch {
                    skipped.append(
                        SkippedFile(name: source.name, reason: error.localizedDescription))
                    NSLog("LegacyMigration: cannot copy \(source.name): \(error)")
                }
                continue
            }

            guard (existingAttributes?[.type] as? FileAttributeType) == .typeRegular else {
                skipped.append(
                    SkippedFile(name: source.name, reason: "destination is not a regular file"))
                NSLog("LegacyMigration: \(destination.path) is not a regular file; skipping")
                continue
            }

            do {
                let legacyData = try Data(contentsOf: source.url)
                let existingData = try Data(contentsOf: destination)

                if legacyData == existingData {
                    // Already identical -- including after an earlier
                    // placeholder replacement below, which is what lets
                    // that path converge instead of reporting a skip
                    // forever.
                    continue
                }

                let existingText = String(data: existingData, encoding: .utf8)
                if let existingText, !hasContentLines(existingText) {
                    // The destination holds nothing but the comment header
                    // this app writes into a fresh user file. Replace it
                    // wholesale, bytes and all -- no decoding, so a legacy
                    // file in some other encoding still arrives rather than
                    // being skipped for ever while the user sees an empty
                    // dictionary.
                    try legacyData.write(to: destination, options: .atomic)
                    changed.append(source.name)
                    continue
                }

                guard let legacyText = String(data: legacyData, encoding: .utf8),
                    let existingText
                else {
                    // Guessing at an unknown encoding risks writing
                    // mojibake into words the user actually has. Say so
                    // instead.
                    skipped.append(
                        SkippedFile(name: source.name, reason: "not valid UTF-8"))
                    NSLog("LegacyMigration: \(source.name) is not valid UTF-8; skipping")
                    continue
                }
                guard
                    let merged = mergedText(
                        legacy: legacyText, existing: existingText,
                        isLatinUserWordList: source.name == latinUserWordListName)
                else {
                    continue
                }
                guard let mergedData = merged.data(using: .utf8) else {
                    skipped.append(SkippedFile(name: source.name, reason: "cannot encode merge"))
                    continue
                }
                try mergedData.write(to: destination, options: .atomic)
                changed.append(source.name)
            } catch {
                skipped.append(SkippedFile(name: source.name, reason: error.localizedDescription))
                NSLog("LegacyMigration: cannot merge \(source.name): \(error)")
            }
        }

        if !skipped.isEmpty {
            return .partial(changed: changed, skipped: skipped)
        }
        return changed.isEmpty ? .notNeeded : .copied(changed: changed)
    }

    /// Set by `migrateIfNeeded` when the user-data half did not happen and
    /// will be retried, so the app can say so once it has a UI to say it
    /// with. Read and cleared by `AppDelegate`; nil the rest of the time.
    ///
    /// A property rather than a direct call because `migrateIfNeeded` runs
    /// from `main.swift` before `NSApp.run()`, where putting a window on
    /// screen is not safe.
    static var pendingUserNotice: MigrationProblem?

    /// What to tell the user, or nil when there is nothing to say. Pure,
    /// so the message rules are testable.
    ///
    /// Returns the problem rather than a sentence: the wording lives in
    /// `AppDelegate` with the rest of the localized strings, so a zh-Hant
    /// user does not get a bare English clause spliced into their notice.
    ///
    /// Only the retryable outcomes produce one. `.copied`, `.notNeeded`
    /// and `.skipped` are successful ends of the story.
    static func userNoticeReason(for outcome: UserDataMigrationOutcome) -> MigrationProblem? {
        switch outcome {
        case .failed(let problem):
            return problem
        case .customLocationUnavailable(let path):
            return .customLocationUnavailable(path: path)
        case .partial(_, let skipped, let legacyFolderPath):
            return .partial(
                skippedNames: skipped.map(\.name), legacyFolderPath: legacyFolderPath)
        case .copied, .notNeeded, .skipped:
            return nil
        }
    }

    /// The whole decision, as a function of its inputs and the file system
    /// it is handed.
    ///
    /// Not pure: the folder merge really happens here. What it does keep
    /// out of reach of a live domain is the *preference* half and both
    /// marker rules -- the part that can permanently lose a user's
    /// dictionary if it is wrong -- which come back as data for
    /// `migrateIfNeeded` to apply, so they can be tested against a
    /// temporary directory.
    ///
    /// The user-data marker is set only for `.copied` and `.notNeeded`.
    /// `.partial`, `.failed` and `.customLocationUnavailable` all leave it
    /// unset so the next launch tries again; because the merge is
    /// idempotent, a retry re-appends nothing it already appended.
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
        let setPrefsMarker = !prefsAlreadyMigrated

        func result(_ outcome: UserDataMigrationOutcome, marker: Bool) -> MigrationResult {
            MigrationResult(
                preferencesToWrite: preferences, userDataOutcome: outcome,
                setPrefsMarker: setPrefsMarker, setUserDataMarker: marker)
        }

        if userDataAlreadyMigrated {
            return result(.skipped("user data marker already set"), marker: false)
        }

        switch legacyUserDataFolder(
            legacyPreferences: legacyPreferences, defaultLegacyFolder: legacyDefaultFolder,
            fileManager: fileManager)
        {
        case .customLocationUnavailable(let path):
            return result(.customLocationUnavailable(path), marker: false)
        case .folder(let folder):
            switch copyUserData(from: folder, to: newFolder, fileManager: fileManager) {
            case .copied(let changed):
                return result(.copied(changed: changed), marker: true)
            case .notNeeded:
                return result(.notNeeded, marker: true)
            case .partial(let changed, let skipped):
                return result(
                    .partial(changed: changed, skipped: skipped, legacyFolderPath: folder.path),
                    marker: false)
            case .failed(let problem):
                return result(.failed(problem), marker: false)
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
        // Say something the first time a set of files cannot be read, and
        // again only if that set changes. A folder with one permanently
        // unreadable file should not greet the user at every launch, but a
        // *different* file failing is news.
        switch result.userDataOutcome {
        case .partial(_, let skipped, _):
            let names = skipped.map(\.name).sorted()
            if names == defaults.stringArray(forKey: skippedFilesKey) {
                pendingUserNotice = nil
            } else {
                defaults.set(names, forKey: skippedFilesKey)
                pendingUserNotice = userNoticeReason(for: result.userDataOutcome)
            }
        case .copied, .notNeeded:
            defaults.removeObject(forKey: skippedFilesKey)
            pendingUserNotice = nil
        case .failed, .customLocationUnavailable, .skipped:
            pendingUserNotice = userNoticeReason(for: result.userDataOutcome)
        }

        NSLog(
            "LegacyMigration: migrated \(result.preferencesToWrite.count) preference key(s) from \(legacyDomain); user data: \(result.userDataOutcome)"
        )
    }
}
