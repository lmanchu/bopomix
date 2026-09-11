#!/bin/bash
#
# Guards the developer's own input-method preferences against the test
# suite (docs/REVIEW-P3-2026-09-11.md's N4).
#
# The XCTest target runs inside the real McBopomofo app host and
# Preferences writes straight through to the live
# org.openvanilla.inputmethod.McBopomofo defaults domain -- the same file
# the *installed* input method reads. A test that set a $TMPDIR path as
# CustomUserPhraseLocation and did not put it back once left the author's
# installed IME writing learned phrases into a folder macOS deletes.
# McBopomofoTests/PreferenceSandbox.swift is the fix; this script is how
# you prove the fix is still working.
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
# Exits non-zero (and prints the diff) if a single key changed, was added,
# or was removed. The command's own exit status is reported separately, so
# a failing test suite that still left preferences alone is distinguishable
# from a passing one that did not.

set -u

DOMAIN="org.openvanilla.inputmethod.McBopomofo"
WORKDIR="$(mktemp -d -t mixime-plist-guard)"
BEFORE="${WORKDIR}/before.plist"
AFTER="${WORKDIR}/after.plist"

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

defaults export "${DOMAIN}" "${BEFORE}"

set +e
"$@"
COMMAND_STATUS=$?
set -e

defaults export "${DOMAIN}" "${AFTER}"

if diff "${BEFORE}" "${AFTER}" > "${WORKDIR}/diff.txt"; then
  echo "PLIST_UNCHANGED (${DOMAIN})"
  exit "${COMMAND_STATUS}"
fi

echo "PLIST_CHANGED (${DOMAIN}) -- the test run modified your real preferences:" >&2
cat "${WORKDIR}/diff.txt" >&2
echo "" >&2
echo "Every XCTest class that touches Preferences must call" >&2
echo "PreferenceSandbox.install(on: self) as the first statement of" >&2
echo "setUpWithError(). See McBopomofoTests/PreferenceSandbox.swift." >&2
exit 1
