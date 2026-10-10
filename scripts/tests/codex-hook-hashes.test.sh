#!/usr/bin/env bash
#
# Tests for scripts/codex-hook-hashes.sh.
#
# `codex` is replaced with a stub app-server that answers `initialize` and
# `hooks/list` with a canned response, so these tests never touch a real Codex
# install.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
HASHES="$REPO_ROOT/scripts/codex-hook-hashes.sh"
JQ_DIR="$(dirname -- "$(command -v jq)")"

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

# --- stub ---------------------------------------------------------------------
# A line-oriented JSON-RPC app-server: replies to id 1 (initialize) and id 2
# (hooks/list, answered from $HOOKS_RESPONSE). It sends a notification first to
# prove the script skips messages that aren't the reply it waits for.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/codex" <<'EOF'
#!/bin/sh
[ "$1" = "app-server" ] || exit 64
while IFS= read -r line; do
    case "$(printf '%s' "$line" | jq -r '.id // empty')" in
        1) echo '{"method":"configWarning","params":{}}'
           echo '{"id":1,"result":{}}' ;;
        2) jq -c '. + {id: 2}' "$HOOKS_RESPONSE" ;;
    esac
done
EOF
chmod +x "$STUBS/codex"

# run_hashes <response.json> [args...]
# Sets the globals STATUS, OUT and ERR.
run_hashes() {
    local response="$1"; shift
    STATUS=0
    OUT="$(env -i PATH="$STUBS:$JQ_DIR:/usr/bin:/bin" HOOKS_RESPONSE="$response" \
        bash "$HASHES" "$@" 2>"$WORK/stderr")" || STATUS=$?
    ERR="$(cat "$WORK/stderr")"
}

hook() { # hook <key> <hash> <trustStatus> [isManaged]
    printf '{"key":"%s","currentHash":"%s","trustStatus":"%s","isManaged":%s}' "$1" "$2" "$3" "${4:-false}"
}

cat > "$WORK/mixed.json" <<EOF
{"result":{"data":[{"cwd":"/w","errors":[],"warnings":[],"hooks":[
  $(hook "zeta@m:hooks.json:stop:0:0" "sha256:zz" untrusted),
  $(hook "alpha@m:hooks.json:session_start:0:0" "sha256:aa" trusted),
  $(hook "beta@m:hooks.json:post_tool_use:0:0" "sha256:bb" modified),
  $(hook "admin:managed.json:stop:0:0" "sha256:mm" managed true)
]}]}}
EOF

cat > "$WORK/trusted.json" <<EOF
{"result":{"data":[{"cwd":"/w","errors":[],"warnings":[],"hooks":[
  $(hook "alpha@m:hooks.json:session_start:0:0" "sha256:aa" trusted),
  $(hook "admin:managed.json:stop:0:0" "sha256:mm" managed true)
]}]}}
EOF

echo '{"error":{"code":-32600,"message":"boom"}}' > "$WORK/error.json"

# --- tests ------------------------------------------------------------------
echo "codex-hook-hashes.sh"

run_hashes "$WORK/mixed.json"
assert_status 0 "prints the trust block"
assert_eq "$OUT" '[hooks.state."alpha@m:hooks.json:session_start:0:0"]
trusted_hash = "sha256:aa"

[hooks.state."beta@m:hooks.json:post_tool_use:0:0"]
trusted_hash = "sha256:bb"

[hooks.state."zeta@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:zz"' "one entry per hook, sorted by key, managed hooks skipped"

run_hashes "$WORK/mixed.json" --check
assert_status 1 "--check fails when a hook is not trusted"
assert_contains "$ERR" "beta@m:hooks.json:post_tool_use:0:0 (modified)" "--check names a modified hook"
assert_contains "$ERR" "zeta@m:hooks.json:stop:0:0 (untrusted)" "--check names an untrusted hook"
assert_not_contains "$ERR" "alpha@m" "--check does not flag a trusted hook"

run_hashes "$WORK/trusted.json" --check
assert_status 0 "--check passes when every hook is trusted"

run_hashes "$WORK/error.json"
assert_status 1 "fails when hooks/list returns an error"
assert_contains "$ERR" "boom" "surfaces the app-server error"

run_hashes "$WORK/mixed.json" --bogus
assert_status 2 "rejects an unknown argument"

# The shipped dotfile must trust every hook the repo's plugins ship (7 as of
# ponytail 5.1.0, impeccable 4.5.2, devkit 0.2.0); the devpod check verifies
# the hashes themselves against the real plugins.
config_entries="$(grep -c '^\[hooks\.state\.' "$REPO_ROOT/.codex/config.toml" || true)"
if [ "$config_entries" -ge 7 ]; then ok "repo config pins trust for the plugins' hooks ($config_entries)"; else bad "repo config pins trust for the plugins' hooks (found $config_entries, want >= 7)"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
