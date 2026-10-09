#!/bin/bash

set -eu
set -o pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$REPO_ROOT/DMG_Watch_Installer.command"
EXPECTED_VERSION="1.0.0"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

[ -f "$SCRIPT" ] || fail "installer script is missing"
[ -x "$SCRIPT" ] || fail "installer script is not executable"
pass "installer script exists and is executable"

/bin/bash -n "$SCRIPT" || fail "Bash syntax validation failed"
pass "Bash syntax"

VERSION_OUTPUT="$($SCRIPT --version)"
[ "$VERSION_OUTPUT" = "DMG Watch Installer $EXPECTED_VERSION" ] || \
    fail "unexpected --version output: $VERSION_OUTPUT"
pass "version output"

HELP_OUTPUT="$($SCRIPT --help)"
printf '%s\n' "$HELP_OUTPUT" | /usr/bin/grep -q -- '--dry-run' || fail "help omits --dry-run"
printf '%s\n' "$HELP_OUTPUT" | /usr/bin/grep -q -- '--no-wait' || fail "help omits --no-wait"
printf '%s\n' "$HELP_OUTPUT" | /usr/bin/grep -q -- 'DMG_MAX_IMAGE_DEPTH' || fail "help omits environment variables"
pass "help output"

set +e
"$SCRIPT" first-folder second-folder > /dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "multiple watch folders did not return exit code 2"

set +e
"$SCRIPT" -- first-folder second-folder > /dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "multiple watch folders after -- did not return exit code 2"
pass "argument validation"

while IFS= read -r -d '' FILE; do
    case "$FILE" in
        "$REPO_ROOT/tests/validate.sh") continue ;;
    esac
    if /usr/bin/grep -nE '/Users/[[:alnum:]_.-]+/|/home/[[:alnum:]_.-]+/|/private/var/folders/[[:alnum:]_./-]+' "$FILE"; then
        fail "repository contains a machine-specific path or host token: $FILE"
    fi
done < <(/usr/bin/find "$REPO_ROOT" -type f ! -path '*/.git/*' -print0)
pass "host-neutral repository content"

while IFS= read -r -d '' FILE; do
    if LC_ALL=C /usr/bin/grep -q $'\r' "$FILE"; then
        fail "repository contains CRLF line endings: $FILE"
    fi
done < <(/usr/bin/find "$REPO_ROOT" -type f ! -path '*/.git/*' -print0)
pass "line endings"

for REQUIRED_FILE in README.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md .gitattributes .gitignore; do
    [ -f "$REPO_ROOT/$REQUIRED_FILE" ] || fail "missing $REQUIRED_FILE"
done
[ -f "$REPO_ROOT/.github/workflows/validate.yml" ] || fail "missing GitHub Actions workflow"
pass "repository metadata"

if [ "$(/usr/bin/uname -s 2>/dev/null || true)" = "Darwin" ]; then
    TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dmg-watch-validation.XXXXXX")"
    trap '/bin/rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
    WATCH_FOLDER="$TEMP_ROOT/watch"
    LOG_FILE="$TEMP_ROOT/installer.log"
    /bin/mkdir -p "$WATCH_FOLDER"

    DMG_LOG_FILE="$LOG_FILE" \
      "$SCRIPT" --dry-run --plain --no-wait "$WATCH_FOLDER" \
      > "$TEMP_ROOT/stdout.txt" 2> "$TEMP_ROOT/stderr.txt" || \
      fail "empty-folder smoke test failed"

    [ -f "$LOG_FILE" ] || fail "smoke test did not create a log"
    /usr/bin/grep -q 'No DMG or ISO files were found' "$LOG_FILE" || \
      fail "smoke test did not reach the empty-queue result"
    pass "macOS empty-folder smoke test"

    set +e
    DMG_MAX_IMAGE_DEPTH=not-a-number \
      "$SCRIPT" --plain --no-wait "$WATCH_FOLDER" \
      > /dev/null 2>&1
    STATUS=$?
    set -e
    [ "$STATUS" -eq 2 ] || fail "invalid recursion depth did not return exit code 2"
    pass "configuration validation"

    /bin/rm -rf "$TEMP_ROOT"
    trap - EXIT HUP INT TERM
else
    printf 'SKIP: macOS runtime smoke test (non-Darwin validation host)\n'
fi

printf '\nAll validation checks passed.\n'
