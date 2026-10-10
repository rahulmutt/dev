#!/usr/bin/env bash
#
# Tests for base/mise-update.sh.
#
# mise is replaced with a stub that records how it was called and can be told
# to fail, so these tests never touch the network or the real toolchain.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
MISE_UPDATE="$REPO_ROOT/base/mise-update.sh"

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
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- stubs ------------------------------------------------------------------
# mise lives in ~/.local/bin, as in the image, not on the inherited PATH.
# MISE_FAIL names the subcommand (self-update or upgrade) that should fail.
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.local/bin"
cat > "$HOME_DIR/.local/bin/mise" <<'EOF'
#!/bin/sh
echo "mise $*" >> "$CALLS"
[ "$1" = "${MISE_FAIL:-}" ] && exit 3
exit 0
EOF
chmod +x "$HOME_DIR/.local/bin/mise"

# The wrapped command: records each argument on its own line, exits with $1.
cat > "$WORK/wrapped" <<'EOF'
#!/bin/sh
code="$1"; shift
echo "wrapped" >> "$CALLS"
for a in "$@"; do echo "arg:$a" >> "$CALLS"; done
exit "$code"
EOF
chmod +x "$WORK/wrapped"

# run_mise_update [VAR=value ...] -- [args...]
# Sets the globals STATUS, CALLS_OUT and STDERR_OUT.
run_mise_update() {
    local calls="$WORK/calls" err="$WORK/stderr" envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    : > "$calls"
    STATUS=0
    env -i HOME="$HOME_DIR" PATH="/usr/bin:/bin" CALLS="$calls" "${envs[@]}" \
        bash "$MISE_UPDATE" "$@" >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

echo "mise-update.sh tests"

# --- no args ----------------------------------------------------------------
run_mise_update --
assert_eq "$STATUS" 0 "exits 0 with no args"
assert_eq "$CALLS_OUT" "$(printf 'mise self-update\nmise upgrade --interactive --bump')" \
    "self-updates, then upgrades interactively with --bump"

# --- wraps a command --------------------------------------------------------
run_mise_update -- "$WORK/wrapped" 0 "two words" plain
assert_eq "$STATUS" 0 "exits 0 when the wrapped command does"
assert_contains "$CALLS_OUT" "$(printf 'mise upgrade --interactive --bump\nwrapped')" "updates before running the command"
assert_contains "$CALLS_OUT" "$(printf 'arg:two words\narg:plain')" "passes args through with quoting intact"

run_mise_update -- "$WORK/wrapped" 7
assert_eq "$STATUS" 7 "propagates the wrapped command's exit code"

# --- update failures don't block the command --------------------------------
run_mise_update MISE_FAIL=self-update -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed self-update still runs the command"
assert_not_contains "$CALLS_OUT" "mise upgrade" "skips upgrade after a failed self-update"
assert_contains "$CALLS_OUT" "wrapped" "runs the command after a failed self-update"
assert_contains "$STDERR_OUT" "mise-update: update failed (exit 3), continuing" "warns on a failed self-update"

run_mise_update MISE_FAIL=upgrade -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed upgrade still runs the command"
assert_contains "$CALLS_OUT" "wrapped" "runs the command after a failed upgrade"
assert_contains "$STDERR_OUT" "update failed (exit 3)" "warns on a failed upgrade"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
