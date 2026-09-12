#!/bin/bash
#
# Guards the developer's own input-method state against the test suite:
# both the preferences domain (docs/REVIEW-P3-2026-09-11.md's N4) and the
# user-data folder (docs/REVERIFY-P3-2026-09-12.md's P-2).
#
# The XCTest target runs inside the real McBopomofo app host and
# Preferences writes straight through to the live
# org.openvanilla.inputmethod.McBopomofo defaults domain -- the same file
# the *installed* input method reads. A test that set a $TMPDIR path as
# CustomUserPhraseLocation and did not put it back once left the author's
# installed IME writing learned phrases into a folder macOS deletes.
# McBopomofoTests/PreferenceSandbox.swift is the fix for that half.
#
# The folder check is here because the plist check alone did not catch the
# worse failure: a `-parallel-testing-enabled YES` run left 130 eval-corpus
# words in ~/Library/Application Support/McBopomofo/latin-user.txt with the
# plist reporting PLIST_UNCHANGED throughout. The test suite redirects its
# data folder through LanguageModelManager.dataFolderOverrideForTesting
# (process-local, unlike the preference key it replaced), so the real
# folder must come out of a run exactly as it went in -- absent if it was
# absent, byte-identical if it existed.
#
# Usage:
#   tools/eval/check_plist_unchanged.sh <command> [args...]
#
# Example:
#   tools/eval/check_plist_unchanged.sh \
#     xcodebuild -project McBopomofo.xcodeproj -scheme McBopomofo \
#       -configuration Debug -derivedDataPath build \
#       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" test
#
# Exits non-zero (and prints the diff) if a single preference key changed,
# was added or removed, or if the user-data folder was created or its
# contents changed. The command's own exit status is reported separately,
# so a failing test suite that still left everything alone is
# distinguishable from a passing one that did not.

set -u

DOMAIN="org.openvanilla.inputmethod.McBopomofo"
DATA_FOLDER="${HOME}/Library/Application Support/McBopomofo"
WORKDIR="$(mktemp -d -t mixime-plist-guard)"
BEFORE="${WORKDIR}/before.plist"
AFTER="${WORKDIR}/after.plist"
FOLDER_BEFORE="${WORKDIR}/folder-before.txt"
FOLDER_AFTER="${WORKDIR}/folder-after.txt"

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# A listing of the data folder that is stable across runs: every file's
# path, size and checksum, or the single line ABSENT when the folder does
# not exist at all (the common case on a machine that has never written a
# user phrase -- and the state a test run must not change).
snapshot_data_folder() {
  if [ ! -d "${DATA_FOLDER}" ]; then
    echo "ABSENT"
    return
  fi
  find "${DATA_FOLDER}" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 -I {} shasum -a 256 "{}" \
    | sed "s|${DATA_FOLDER}|<data folder>|"
}

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

defaults export "${DOMAIN}" "${BEFORE}"
snapshot_data_folder > "${FOLDER_BEFORE}"

set +e
"$@"
COMMAND_STATUS=$?
set -e

defaults export "${DOMAIN}" "${AFTER}"
snapshot_data_folder > "${FOLDER_AFTER}"

STATUS=0

if diff "${BEFORE}" "${AFTER}" > "${WORKDIR}/plist-diff.txt"; then
  echo "PLIST_UNCHANGED (${DOMAIN})"
else
  echo "PLIST_CHANGED (${DOMAIN}) -- the test run modified your real preferences:" >&2
  cat "${WORKDIR}/plist-diff.txt" >&2
  echo "" >&2
  echo "Every XCTest class that touches Preferences must call" >&2
  echo "PreferenceSandbox.install(on: self) as the first statement of" >&2
  echo "setUpWithError(). See McBopomofoTests/PreferenceSandbox.swift." >&2
  STATUS=1
fi

if diff "${FOLDER_BEFORE}" "${FOLDER_AFTER}" > "${WORKDIR}/folder-diff.txt"; then
  echo "DATA_FOLDER_UNCHANGED (${DATA_FOLDER})"
else
  echo "DATA_FOLDER_CHANGED (${DATA_FOLDER}) -- the test run wrote into your real" >&2
  echo "input method's user data:" >&2
  cat "${WORKDIR}/folder-diff.txt" >&2
  echo "" >&2
  echo "Tests must redirect their user-data folder with" >&2
  echo "LanguageModelManager.dataFolderOverrideForTesting, never through the" >&2
  echo "UseCustomUserPhraseLocation / CustomUserPhraseLocation preference keys," >&2
  echo "which every process on this machine shares. See" >&2
  echo "docs/REVERIFY-P3-2026-09-12.md's P-2." >&2
  STATUS=1
fi

if [ "${STATUS}" -ne 0 ]; then
  exit "${STATUS}"
fi
exit "${COMMAND_STATUS}"
