#!/usr/bin/env bash
#
# Tests for base/env-update.sh.
#
# mise and the dotfiles installer are replaced with stubs that record how they
# were called and can be told to fail, so these tests never touch the network,
# the real toolchain or the real dotfiles.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ENV_UPDATE="$REPO_ROOT/base/env-update.sh"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi
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

# The dotfiles installer: records the call, exits with $SYNC_FAIL (default 0).
cat > "$WORK/install.sh" <<'EOF'
#!/bin/sh
echo "sync-dotfiles" >> "$CALLS"
exit "${SYNC_FAIL:-0}"
EOF

# The wrapped command: records each argument on its own line, exits with $1.
cat > "$WORK/wrapped" <<'EOF'
#!/bin/sh
code="$1"; shift
echo "wrapped" >> "$CALLS"
for a in "$@"; do echo "arg:$a" >> "$CALLS"; done
exit "$code"
EOF
chmod +x "$WORK/wrapped"

# run_env_update [VAR=value ...] -- [args...]
# Sets the globals STATUS, CALLS_OUT and STDERR_OUT.
run_env_update() {
    local calls="$WORK/calls" err="$WORK/stderr" envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    : > "$calls"
    STATUS=0
    env -i HOME="$HOME_DIR" PATH="/usr/bin:/bin" CALLS="$calls" DOTFILES_INSTALL="$WORK/install.sh" "${envs[@]}" \
        bash "$ENV_UPDATE" "$@" >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

echo "env-update.sh tests"

# --- no args ----------------------------------------------------------------
run_env_update --
assert_eq "$STATUS" 0 "exits 0 with no args"
assert_eq "$CALLS_OUT" "$(printf 'mise self-update\nsync-dotfiles\nmise upgrade --interactive --bump')" \
    "self-updates, syncs the dotfiles, then upgrades interactively with --bump"

# --- wraps a command --------------------------------------------------------
run_env_update -- "$WORK/wrapped" 0 "two words" plain
assert_eq "$STATUS" 0 "exits 0 when the wrapped command does"
assert_contains "$CALLS_OUT" "$(printf 'mise upgrade --interactive --bump\nwrapped')" "updates before running the command"
assert_contains "$CALLS_OUT" "$(printf 'arg:two words\narg:plain')" "passes args through with quoting intact"

run_env_update -- "$WORK/wrapped" 7
assert_eq "$STATUS" 7 "propagates the wrapped command's exit code"

# --- a failed step doesn't block the rest -----------------------------------
run_env_update MISE_FAIL=self-update -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed self-update still runs the command"
assert_contains "$CALLS_OUT" "$(printf 'sync-dotfiles\nmise upgrade --interactive --bump\nwrapped')" "syncs and upgrades after a failed self-update"
assert_contains "$STDERR_OUT" "env-update: mise self-update failed (exit 3), continuing" "warns on a failed self-update"

run_env_update SYNC_FAIL=1 -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed sync still runs the command"
assert_contains "$CALLS_OUT" "$(printf 'sync-dotfiles\nmise upgrade --interactive --bump\nwrapped')" "upgrades after a failed sync"
assert_contains "$STDERR_OUT" "env-update: dotfiles sync failed (exit 1), continuing" "warns on a failed sync"

run_env_update MISE_FAIL=upgrade -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed upgrade still runs the command"
assert_contains "$CALLS_OUT" "wrapped" "runs the command after a failed upgrade"
assert_contains "$STDERR_OUT" "toolchain upgrade failed (exit 3)" "warns on a failed upgrade"

# --- the image ships the installer where env-update looks for it -------------
assert_contains "$(cat "$REPO_ROOT/base/Dockerfile")" "./scripts/install.sh /usr/local/share/dev/install.sh" \
    "the image ships install.sh at env-update's default path"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
