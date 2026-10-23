#!/usr/bin/env bash
#
# Tests for .claude/usage-snapshot.sh.
#
# `curl` is replaced with a stub that records its arguments and the headers it
# was handed on stdin, and answers with $STUB_BODY, so these tests never touch
# the network or a real login.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SNAPSHOT="$REPO_ROOT/.claude/usage-snapshot.sh"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3"; printf '    expected:\n%s\n    got:\n%s\n' "$2" "$1"; fi
}
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi
}
assert_status() {
    if [ "$STATUS" -eq "$1" ]; then ok "$2"; else bad "$2 (exited $STATUS)"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

JQ_DIR="$(dirname "$(command -v jq)")"

# --- stub ---------------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
echo "args: $*" >> "$CALLS"
sed 's/^/stdin: /' >> "$CALLS"
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
printf '%s' "$STUB_BODY"
EOF
chmod +x "$STUBS/curl"

BODY_OK='{
  "five_hour": {"utilization": 17.0, "resets_at": "2026-10-23T17:40:00+00:00"},
  "seven_day": {"utilization": 74.0, "resets_at": "2026-10-29T05:00:00+00:00"},
  "limits": [
    {"kind": "session", "percent": 17, "resets_at": "2026-10-23T17:40:00+00:00", "scope": null},
    {"kind": "weekly_scoped", "percent": 100, "resets_at": "2026-10-29T05:00:00+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}},
    {"kind": "weekly_scoped", "percent": 5, "resets_at": "2026-10-29T05:00:00+00:00",
     "scope": {"model": null, "surface": "cowork"}}
  ]
}'

# new_home <name> [token]: a HOME with a file login (none if token is empty).
new_home() {
    local h="$WORK/$1"
    mkdir -p "$h/.claude"
    [ -n "${2-}" ] && printf '{"claudeAiOauth": {"accessToken": "%s"}}\n' "$2" > "$h/.claude/.credentials.json"
    printf '%s' "$h"
}

# run_snapshot <home> [VAR=value ...]: sets STATUS, CALLS_OUT and SNAP (the
# written snapshot, or empty).
run_snapshot() {
    local home="$1"; shift
    : > "$WORK/calls"
    STATUS=0
    env -i HOME="$home" PATH="$STUBS:$JQ_DIR:/usr/bin:/bin" CALLS="$WORK/calls" STUB_BODY="$BODY_OK" "$@" \
        bash "$SNAPSHOT" >/dev/null 2>&1 || STATUS=$?
    CALLS_OUT="$(cat "$WORK/calls")"
    SNAP="$(cat "$home/.cache/claude-hud/usage.json" 2>/dev/null || true)"
}

echo "usage-snapshot.sh"

H="$(new_home ok tok-123)"
run_snapshot "$H"
assert_status 0 "succeeds with a login"
assert_eq "$(jq -c 'del(.updated_at)' <<<"$SNAP")" \
    '{"five_hour":{"used_percentage":17.0,"resets_at":"2026-10-23T17:40:00+00:00"},"seven_day":{"used_percentage":74.0,"resets_at":"2026-10-29T05:00:00+00:00"},"model_scoped":[{"display_name":"Fable","utilization":100,"resets_at":"2026-10-29T05:00:00+00:00"}]}' \
    "maps the windows, keeping only per-model weekly ones"
assert_contains "$(jq -r .updated_at <<<"$SNAP")" "T" "stamps updated_at"
assert_eq "$(stat -c %a "$H/.cache/claude-hud/usage.json")" "600" "writes the snapshot private"
assert_contains "$CALLS_OUT" "stdin: Authorization: Bearer tok-123" "sends the token as a header on stdin"
assert_not_contains "$(grep '^args:' <<<"$CALLS_OUT")" "tok-123" "never puts the token in curl's arguments"

before="$SNAP"
run_snapshot "$H" STUB_CURL_FAIL=1
assert_status 0 "exits 0 when the request fails"
assert_eq "$SNAP" "$before" "keeps the old snapshot when the request fails"

run_snapshot "$H" STUB_BODY='{"error": {"type": "authentication_error"}}'
assert_status 0 "exits 0 on a body without windows"
assert_eq "$SNAP" "$before" "keeps the old snapshot on a body without windows"
assert_eq "$(find "$H/.cache/claude-hud" -name 'usage.json.*' | wc -l)" "0" "leaves no temp files"

H="$(new_home nologin)"
run_snapshot "$H"
assert_status 0 "exits 0 without a login"
assert_eq "$CALLS_OUT" "" "makes no request without a login"
assert_eq "$SNAP" "" "writes nothing without a login"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
