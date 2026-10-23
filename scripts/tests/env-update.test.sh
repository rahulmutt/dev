#!/usr/bin/env bash
#
# Tests for base/env-update.sh.
#
# mise and the agent CLIs are stubs, and the dotfiles repo is a local fixture
# whose scripts are stubs too; each records how it was called and can be told
# to fail. So these tests never touch the network, the real toolchain or the
# real dotfiles.
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
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi
}
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3"; printf '    expected:\n%s\n    got:\n%s\n' "$2" "$1"; fi
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

# The agent CLIs only need to exist; their plugin scripts are stubbed below.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for t in claude codex pi; do printf '#!/bin/sh\nexit 0\n' > "$TOOLS/$t"; chmod +x "$TOOLS/$t"; done

# The dotfiles repo: each script records "<name> <args>" and exits with
# $FAIL_<NAME> (e.g. FAIL_SYNC_DOTFILES), default 0.
FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE/scripts"
for s in sync-dotfiles install-claude-plugins install-codex-plugins install-pi-packages codex-hook-hashes; do
    var="FAIL_$(printf '%s' "$s" | tr 'a-z-' 'A-Z_')"
    # shellcheck disable=SC2016 # $* and ${...} belong to the stub, not this shell
    printf '#!/bin/sh\necho "%s${*:+ $*}" >> "$CALLS"\nexit "${%s:-0}"\n' "$s" "$var" > "$FIXTURE/scripts/$s.sh"
done
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" add -A
git -C "$FIXTURE" -c user.name=t -c user.email=t@t commit -q -m fixture

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
# Sets the globals STATUS, CALLS_OUT, STDOUT_OUT and STDERR_OUT. The agent CLIs
# are on PATH unless TOOLS_DIR is overridden.
run_env_update() {
    local calls="$WORK/calls" out="$WORK/stdout" err="$WORK/stderr" envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    : > "$calls"
    rm -rf "$WORK/tmp" && mkdir -p "$WORK/tmp"
    STATUS=0
    env -i HOME="$HOME_DIR" PATH="${TOOLS_DIR-$TOOLS}:/usr/bin:/bin" CALLS="$calls" TMPDIR="$WORK/tmp" \
        DOTFILES_REPO="file://$FIXTURE" "${envs[@]}" \
        bash "$ENV_UPDATE" "$@" >"$out" 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDOUT_OUT="$(cat "$out")"
    STDERR_OUT="$(cat "$err")"
}

echo "env-update.sh tests"

# --- the full run -------------------------------------------------------------
run_env_update --
assert_eq "$STATUS" 0 "exits 0 with no args"
assert_eq "$CALLS_OUT" "mise self-update
sync-dotfiles
mise upgrade --interactive --bump
install-claude-plugins --update
install-codex-plugins --update
install-pi-packages --update
codex-hook-hashes --check" \
    "self-updates, syncs, upgrades, updates each tool's plugins, then checks codex hook trust"
assert_eq "$(ls -A "$WORK/tmp")" "" "removes its clone"

# --- wraps a command --------------------------------------------------------
run_env_update -- "$WORK/wrapped" 0 "two words" plain
assert_eq "$STATUS" 0 "exits 0 when the wrapped command does"
assert_contains "$CALLS_OUT" "$(printf 'codex-hook-hashes --check\nwrapped')" "updates before running the command"
assert_contains "$CALLS_OUT" "$(printf 'arg:two words\narg:plain')" "passes args through with quoting intact"

run_env_update -- "$WORK/wrapped" 7
assert_eq "$STATUS" 7 "propagates the wrapped command's exit code"
assert_eq "$(ls -A "$WORK/tmp")" "" "removes its clone before exec'ing the command"

# --- a failed step doesn't block the rest -----------------------------------
run_env_update MISE_FAIL=self-update -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed self-update still runs the command"
assert_contains "$CALLS_OUT" "$(printf 'sync-dotfiles\nmise upgrade --interactive --bump')" "syncs and upgrades after a failed self-update"
assert_contains "$STDERR_OUT" "env-update: mise self-update failed (exit 3), continuing" "warns on a failed self-update"

run_env_update FAIL_SYNC_DOTFILES=1 -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed or declined sync still runs the command"
assert_contains "$CALLS_OUT" "install-pi-packages --update" "updates plugins after a failed sync"
assert_contains "$STDERR_OUT" "env-update: dotfiles sync failed (exit 1), continuing" "warns on a failed sync"

run_env_update FAIL_INSTALL_CODEX_PLUGINS=1 -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed plugin update still runs the command"
assert_contains "$CALLS_OUT" "install-pi-packages --update" "moves on to the next tool's plugins"
assert_contains "$STDERR_OUT" "codex plugin update failed (exit 1)" "warns on a failed plugin update"

run_env_update FAIL_CODEX_HOOK_HASHES=1 -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "stale codex hook trust still runs the command"
assert_contains "$STDERR_OUT" "paste the output of scripts/codex-hook-hashes.sh" "says how to re-trust"

run_env_update MISE_FAIL=upgrade -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed upgrade still runs the command"
assert_contains "$STDERR_OUT" "toolchain upgrade failed (exit 3)" "warns on a failed upgrade"

# --- no clone, no tools -------------------------------------------------------
run_env_update DOTFILES_REPO="file://$WORK/nowhere" -- "$WORK/wrapped" 0
assert_eq "$STATUS" 0 "a failed clone still runs the command"
assert_eq "$CALLS_OUT" "$(printf 'mise self-update\nmise upgrade --interactive --bump\nwrapped')" \
    "skips the sync and plugins but still upgrades without a clone"
assert_contains "$STDERR_OUT" "cloning file://$WORK/nowhere failed" "warns on a failed clone"

TOOLS_DIR="$WORK/empty" run_env_update --
assert_not_contains "$CALLS_OUT" "install-" "skips plugins for tools that aren't installed"
assert_not_contains "$CALLS_OUT" "codex-hook-hashes" "skips the hook check without codex"
assert_contains "$STDOUT_OUT" "claude not installed, skipping its plugins" "says which tool it skipped"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
