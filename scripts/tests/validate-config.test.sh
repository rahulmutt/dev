#!/usr/bin/env bash
#
# Tests for scripts/validate-config.sh.
#
# claude, codex and the codex hook check are replaced with stubs, and each test
# runs against a fixture HOME, so these tests never touch the network or the
# real dotfiles.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate-config.sh"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

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

# jq is a mise tool here, not necessarily in /usr/bin.
JQ_DIR="$(dirname "$(command -v jq)")"

# --- stubs ------------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# claude: `doctor` reports invalid settings when the file under $HOME holds a
# known-bad marker (unless STUB_DOCTOR_BLIND is set, simulating a wording
# change); `plugin install` fails for $STUB_MISSING_PLUGIN.
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$CALLS"
case "$1" in
    doctor)
        if [ -z "${STUB_DOCTOR_BLIND:-}" ] && grep -qE 'notAMode|BADKEY' "$HOME/.claude/settings.json" 2>/dev/null; then
            printf 'Invalid settings\n- %s/.claude/settings.json > bad value\n\nOther stuff\n' "$HOME"
        fi
        exit 0 ;;
    plugin)
        if [ "$2" = install ] && [ "$3" = "${STUB_MISSING_PLUGIN:-}" ]; then
            echo "Plugin not found"; exit 1
        fi
        exit 0 ;;
esac
EOF

# codex: `doctor --json` reports config.load with $STUB_CODEX_STATUS (default
# ok; "missing" omits the check; "garbage" prints non-JSON) and, like the real
# one without auth, exits 1. `plugin list` lists superpowers unless
# STUB_CODEX_PLUGIN_GONE is set.
cat > "$STUBS/codex" <<'EOF'
#!/bin/sh
echo "codex $*" >> "$CALLS"
case "$1" in
    doctor)
        case "${STUB_CODEX_STATUS:-ok}" in
            missing) echo '{"checks":{}}' ;;
            garbage) echo 'not json' ;;
            *) printf '{"checks":{"config.load":{"status":"%s","summary":"config loaded","details":{"warnings":"Codex is ignoring 1 unrecognized configuration setting."}}}}\n' "${STUB_CODEX_STATUS:-ok}" ;;
        esac
        exit 1 ;;
    plugin)
        [ -z "${STUB_CODEX_PLUGIN_GONE:-}" ] && echo "superpowers@superpowers-dev    installed, enabled"
        exit 0 ;;
esac
EOF

cat > "$STUBS/hook-hashes" <<'EOF'
#!/bin/sh
echo "hook-hashes $*" >> "$CALLS"
if [ -n "${STUB_HOOKS_STALE:-}" ]; then echo "codex hooks not trusted" >&2; exit 1; fi
echo "all 1 codex hooks trusted"
EOF
chmod +x "$STUBS"/*

# make_home <dir>: a fixture HOME whose dotfiles all pass.
make_home() {
    local h="$1"
    mkdir -p "$h/.claude" "$h/.codex" "$h/.pi/agent/npm/node_modules/pi-foo" "$h/.pi/agent/git/github.com/o/r"
    cat > "$h/.claude/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "/home/dev/.local/share/mise/installs/bun/latest/bin/bun x"},
  "enabledPlugins": {
    "devkit@devkit-marketplace": true,
    "code-review@claude-plugins-official": true,
    "nono@always-further": true,
    "off@devkit-marketplace": false
  },
  "extraKnownMarketplaces": {
    "devkit-marketplace": {"source": {"source": "github", "repo": "rahulmutt/devkit"}}
  }
}
EOF
    cat > "$h/.codex/config.toml" <<'EOF'
model = "gpt-5.5"

[plugins."superpowers@superpowers-dev"]
enabled = true

[plugins."disabled@x"]
enabled = false
EOF
    cat > "$h/.pi/agent/settings.json" <<'EOF'
{"packages": ["npm:pi-foo", "git:github.com/o/r"]}
EOF
}

# run_validate <home> [VAR=value ...]: sets STATUS, OUT and CALLS_OUT.
run_validate() {
    local home="$1"; shift
    : > "$WORK/calls"
    STATUS=0
    OUT="$(env -i HOME="$home" PATH="$STUBS:$JQ_DIR:/usr/bin:/bin" CALLS="$WORK/calls" \
        CODEX_HOOK_HASHES="$STUBS/hook-hashes" "$@" bash "$VALIDATE" 2>&1)" || STATUS=$?
    # shellcheck disable=SC2034  # read by the claude/codex call assertions in later tasks
    CALLS_OUT="$(cat "$WORK/calls")"
}

echo "validate-config.sh tests"

# --- clean fixture ------------------------------------------------------------
H="$WORK/clean"; make_home "$H"
run_validate "$H"
assert_status 0 "a clean HOME passes"
assert_contains "$OUT" "config OK" "reports success"
assert_not_contains "$OUT" "FAIL" "no failing checks"

# --- pinned-path drift ------------------------------------------------------
echo
echo "test: a versioned mise install path fails"
H="$WORK/drift"; make_home "$H"
sed -i 's|installs/bun/latest|installs/bun/1.4.2|' "$H/.claude/settings.json"
run_validate "$H"
assert_status 1 "exits 1"
assert_contains "$OUT" "installs/bun/1.4.2" "names the offending path"

echo
echo "test: a major-version symlink path also fails"
H="$WORK/major"; make_home "$H"
sed -i 's|installs/bun/latest|installs/node/26|' "$H/.claude/settings.json"
run_validate "$H"
assert_status 1 "exits 1 for installs/node/26"

# --- pi -----------------------------------------------------------------------
echo
echo "test: non-string pi packages fail"
H="$WORK/pi-bad"; make_home "$H"
echo '{"packages": ["npm:pi-foo", 3]}' > "$H/.pi/agent/settings.json"
run_validate "$H"
assert_status 1 "exits 1"
assert_contains "$OUT" "FAIL  pi settings.json" "pi settings check fails"

echo
echo "test: pi settings without packages pass"
H="$WORK/pi-none"; make_home "$H"
echo '{"quietStartup": "header"}' > "$H/.pi/agent/settings.json"
run_validate "$H"
assert_status 0 "exits 0"

echo
echo "test: a declared pi package that isn't installed fails"
H="$WORK/pi-missing"; make_home "$H"
rm -rf "$H/.pi/agent/npm/node_modules/pi-foo"
run_validate "$H"
assert_status 1 "exits 1"
assert_contains "$OUT" "pi package npm:pi-foo not installed" "names the package"

echo
echo "test: a missing settings file fails"
H="$WORK/no-pi"; make_home "$H"
rm "$H/.pi/agent/settings.json"
run_validate "$H"
assert_status 1 "exits 1"
assert_contains "$OUT" "missing" "says the file is missing"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
