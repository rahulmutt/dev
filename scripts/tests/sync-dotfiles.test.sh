#!/usr/bin/env bash
#
# Integration tests for scripts/sync-dotfiles.sh, focused on the safe-backup
# behaviour: identical files are skipped, differing files are backed up next to
# the original before being overwritten, and git-ignored files are never synced.
#
# Each test runs the real script against a throwaway $HOME built from a fake
# source repo, so nothing on the developer's machine is touched. Fixtures live
# under the dotfile roots the script actually syncs (.config, .pi, ...).
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/sync-dotfiles.sh"

# the tracked dotfile we edit/back up throughout the tests
RC=".config/demo/rc"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_file_exists() {
    if [ -e "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}
assert_no_file() {
    if [ ! -e "$1" ]; then ok "$2"; else bad "$2 (unexpectedly present: $1)"; fi
}
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi
}
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi
}
# count files matching a glob (literal pattern survives when nothing matches).
# The unquoted $1 is deliberate: we want the glob to expand into positionals.
# shellcheck disable=SC2086
count_glob() { set -- $1; { [ -e "$1" ] && echo "$#"; } || echo 0; }

# --- build a throwaway "source repo" ----------------------------------------
# A minimal git repo with tracked dotfiles under real roots plus a git-ignored
# secret, so assertions are deterministic and independent of the real repo.
make_src_repo() {
    local src="$1"
    mkdir -p "$src/.config/demo" "$src/.pi/agent"
    printf 'tracked\n'            > "$src/$RC"
    printf 'version = 1\n'        > "$src/.config/demo/config.toml"
    printf 'SECRET=do-not-sync\n' > "$src/.pi/agent/auth.json"   # excluded below
    printf '/.pi/agent/auth.json\n' > "$src/.gitignore"

    git -C "$src" init -q -b main
    git -C "$src" -c user.email=t@t -c user.name=t add -A
    git -C "$src" -c user.email=t@t -c user.name=t commit -qm init
}

# Run the real sync script, but as a copy living inside the fake repo, so its
# "one level up from scripts/" root detection resolves to the fake repo.
run_sync() {
    local src="$1" home="$2"; shift 2
    mkdir -p "$src/scripts"
    cp "$SYNC" "$src/scripts/sync-dotfiles.sh"
    bash "$src/scripts/sync-dotfiles.sh" --home "$home" "$@"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "sync-dotfiles backup integration tests"

# ===========================================================================
echo
echo "test: fresh sync copies tracked files and skips git-ignored secrets"
SRC="$WORK/src"; HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
make_src_repo "$SRC"
run_sync "$SRC" "$HOME_DIR" --yes >/dev/null
assert_file_exists "$HOME_DIR/$RC" "tracked dotfile copied"
assert_file_exists "$HOME_DIR/.config/demo/config.toml" "second tracked dotfile copied"
assert_no_file "$HOME_DIR/.pi/agent/auth.json" "git-ignored secret NOT synced"

# ===========================================================================
echo
echo "test: unchanged re-sync makes no backups"
run_sync "$SRC" "$HOME_DIR" --yes >/dev/null
assert_eq "$(count_glob "$HOME_DIR/$RC.bak.*")" "0" "no backup created when nothing changed"

# ===========================================================================
echo
echo "test: a locally-modified file is backed up adjacent, then overwritten"
printf 'tracked\nLOCAL EDIT\n' > "$HOME_DIR/$RC"
OUT="$(run_sync "$SRC" "$HOME_DIR" --yes)"
assert_eq "$(count_glob "$HOME_DIR/$RC.bak.*")" "1" "exactly one adjacent backup created"
BAK="$(echo "$HOME_DIR/$RC".bak.*)"
assert_eq "$(dirname "$BAK")" "$HOME_DIR/.config/demo" "backup sits next to the original, not in a central dir"
assert_contains "$(cat "$BAK")" "LOCAL EDIT" "backup preserves the previous local contents"
assert_eq "$(cat "$HOME_DIR/$RC")" "tracked" "live file overwritten with repo version"
assert_contains "$OUT" "1 file(s) updated" "summary reports one update"
assert_no_file "$HOME_DIR/.dotfiles-sync-backups" "no central backup directory is created"

# ===========================================================================
echo
echo "test: repeated edits produce distinct timestamped backups, none clobbered"
printf 'tracked\nEDIT TWO\n' > "$HOME_DIR/$RC"
# shim `date` so this run lands on a different timestamp than the first backup
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\necho "29991231-235959"\n' > "$SHIM/date"
chmod +x "$SHIM/date"
PATH="$SHIM:$PATH" run_sync "$SRC" "$HOME_DIR" --yes >/dev/null
assert_file_exists "$HOME_DIR/$RC.bak.29991231-235959" "second backup uses its own timestamp"
assert_eq "$(count_glob "$HOME_DIR/$RC.bak.*")" "2" "both backups retained (earlier one not clobbered)"
assert_contains "$(cat "$HOME_DIR/$RC.bak.29991231-235959")" "EDIT TWO" "second backup holds the second edit"

# ===========================================================================
echo
echo "test: --dry-run reports changes but writes nothing"
printf 'tracked\nDRY EDIT\n' > "$HOME_DIR/$RC"
BEFORE="$(count_glob "$HOME_DIR/$RC.bak.*")"
OUT="$(run_sync "$SRC" "$HOME_DIR" --dry-run)"
assert_contains "$OUT" "Dry run" "dry-run announces itself"
assert_contains "$OUT" "changed $RC" "dry-run lists the changed file"
assert_eq "$(count_glob "$HOME_DIR/$RC.bak.*")" "$BEFORE" "dry-run created no backups"
assert_contains "$(cat "$HOME_DIR/$RC")" "DRY EDIT" "dry-run left the local file untouched"

# ===========================================================================
echo
echo "test: --verbose shows a diff for changed files and lists unchanged ones"
# $RC in home still differs from the repo (left as 'DRY EDIT' above); config.toml
# was synced in test 1 and never touched, so it is identical.
OUT="$(run_sync "$SRC" "$HOME_DIR" --dry-run --verbose)"
assert_contains "$OUT" "changed $RC" "verbose still lists the changed file"
assert_contains "$OUT" "-DRY EDIT" "verbose diff shows the removed local line"
assert_contains "$OUT" "@@" "verbose diff includes a unified-diff hunk header"
assert_contains "$OUT" "ok      .config/demo/config.toml" "verbose names an unchanged file"
# the default (non-verbose) run must not print any diff body
OUT="$(run_sync "$SRC" "$HOME_DIR" --dry-run)"
assert_not_contains "$OUT" "-DRY EDIT" "non-verbose prints no diff"
assert_not_contains "$OUT" "ok      .config/demo/config.toml" "non-verbose does not list unchanged files"

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$PASS"
    exit 0
else
    printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
