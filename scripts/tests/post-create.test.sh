#!/usr/bin/env bash
#
# Tests for base/post-create.sh.
#
# The script's collaborators (mise, nix, curl, sudo, nvim) are replaced with
# stubs that only record how they were called, so these tests never touch the
# network or the real toolchain.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
POST_CREATE="$REPO_ROOT/base/post-create.sh"

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
    local expected="$1"
    local message="$2"
    if [ "$STATUS" -eq "$expected" ]; then
        ok "$message"
    else
        bad "$message (exited $STATUS)"
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- stubs ------------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
for cmd in mise nix curl sudo nvim tmux; do
    cat > "$STUBS/$cmd" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> "$CALLS"
EOF
    chmod +x "$STUBS/$cmd"
done

# run_post_create <workspace> [VAR=value ...]
# Runs the script in <workspace> with a scrubbed environment. Sets the globals
# STATUS, CALLS_OUT and STDERR_OUT.
run_post_create() {
    local ws="$1"; shift
    local calls="$WORK/calls" err="$WORK/stderr"
    : > "$calls"
    mkdir -p "$WORK/home"
    STATUS=0
    (cd "$ws" && env -i HOME="$WORK/home" PATH="$STUBS:/usr/bin:/bin" CALLS="$calls" "$@" \
        bash "$POST_CREATE") >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

echo "post-create.sh tests"

# --- workspace with its own mise.toml ---------------------------------------
WS="$WORK/ws-with-config"
mkdir -p "$WS"
touch "$WS/mise.toml"
run_post_create "$WS"
assert_status 0 "exits 0 with a workspace mise.toml"
assert_contains "$CALLS_OUT" "mise trust --yes mise.toml" "trusts the workspace mise.toml"
assert_contains "$CALLS_OUT" "mise install" "installs workspace tools"
assert_not_contains "$CALLS_OUT" "nvim" "does not sync nvim plugins (done at build time)"
assert_not_contains "$STDERR_OUT" "no longer needed" "no notice without INSTALL_* vars"

# --- bare workspace ---------------------------------------------------------
WS="$WORK/ws-bare"
mkdir -p "$WS"
run_post_create "$WS"
assert_status 0 "exits 0 in a bare workspace"
assert_not_contains "$CALLS_OUT" "mise trust" "trusts nothing when no config exists"
assert_contains "$CALLS_OUT" "mise install" "still runs mise install"

# --- legacy INSTALL_* vars --------------------------------------------------
run_post_create "$WS" INSTALL_NIX=true INSTALL_DEVENV=true
assert_status 0 "legacy INSTALL_* vars are not an error"
assert_contains "$STDERR_OUT" "INSTALL_NIX is no longer needed" "notice for INSTALL_NIX"
assert_contains "$STDERR_OUT" "INSTALL_DEVENV is no longer needed" "notice for INSTALL_DEVENV"
for cmd in nix curl sudo; do
    assert_not_contains "$CALLS_OUT" "$cmd " "does not call $cmd"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
