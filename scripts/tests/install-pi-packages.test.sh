#!/usr/bin/env bash
#
# Tests for scripts/install-pi-packages.sh.
#
# `pi` is replaced with a stub that only records how it was called, so these
# tests never touch the network or a real pi install.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install-pi-packages.sh"

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
assert_status() {
    if [ "$STATUS" -eq "$1" ]; then ok "$2"; else bad "$2 (exited $STATUS)"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- stub ---------------------------------------------------------------------
# Records each call; exits 1 when the call matches $PI_FAIL_ON.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/pi" <<'EOF'
#!/bin/sh
echo "pi $*" >> "$CALLS"
case "$*" in *"${PI_FAIL_ON:-<never>}"*) exit 1 ;; esac
EOF
chmod +x "$STUBS/pi"

# run_install <home> [VAR=value ...]; script args come from $INSTALL_ARGS.
# Sets the globals STATUS, CALLS_OUT and STDERR_OUT.
run_install() {
    local home="$1"; shift
    local calls="$WORK/calls" err="$WORK/stderr"
    : > "$calls"
    STATUS=0
    env -i PATH="$STUBS:/usr/bin:/bin:$(dirname "$(command -v jq)")" CALLS="$calls" HOME="$home" "$@" \
        bash "$INSTALL" ${INSTALL_ARGS:+"$INSTALL_ARGS"} >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

new_home() {
    local home="$WORK/$1"
    mkdir -p "$home/.pi/agent"
    cat > "$home/.pi/agent/settings.json"
    printf '%s' "$home"
}

# --- tests ------------------------------------------------------------------
echo "install-pi-packages.sh"

home="$(new_home basic <<'EOF'
{"packages": ["npm:alpha", "git:github.com/o/beta", "npm:gamma@1.0.1"], "quietStartup": "header"}
EOF
)"
run_install "$home"
assert_status 0 "succeeds on valid settings"
assert_eq "$CALLS_OUT" "pi install npm:alpha
pi install git:github.com/o/beta
pi install npm:gamma@1.0.1" "installs every declared package, pinned ones included"

INSTALL_ARGS=--update run_install "$home"
assert_status 0 "succeeds with --update"
assert_eq "$CALLS_OUT" "pi install npm:alpha
pi install git:github.com/o/beta
pi install npm:gamma@1.0.1
pi update --extensions" "--update installs, then updates the extensions"

INSTALL_ARGS=--bogus run_install "$home"
assert_status 2 "rejects an unknown argument"

run_install "$home" PI_FAIL_ON="install git:github.com/o/beta"
assert_status 1 "fails when a package cannot be installed"

run_install "$WORK/missing"
assert_status 1 "fails when settings.json is missing"
assert_contains "$STDERR_OUT" "settings.json" "names the missing settings"

# The shipped dotfile is the real input: guard the wiring itself.
mkdir -p "$WORK/repo/.pi/agent"
cp "$REPO_ROOT/.pi/agent/settings.json" "$WORK/repo/.pi/agent/settings.json"
run_install "$WORK/repo"
assert_status 0 "installs from the repo's .pi/agent/settings.json"
assert_contains "$CALLS_OUT" "pi install git:github.com/obra/superpowers" "repo settings install superpowers"
assert_contains "$CALLS_OUT" "pi install npm:pi-dynamic-workflows@1.0.1" "repo settings install the pinned package"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
