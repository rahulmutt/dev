#!/usr/bin/env bash
#
# Tests for scripts/install-claude-plugins.sh.
#
# `claude` is replaced with a stub that only records how it was called (and,
# like the real one, rewrites settings.json), so these tests never touch the
# network or a real Claude install.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install-claude-plugins.sh"

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
# Records each call, reorders settings.json the way the real claude does, and
# exits 1 when the call matches $CLAUDE_FAIL_ON.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >> "$CALLS"
f="$CLAUDE_CONFIG_DIR/settings.json"
jq -S . "$f" > "$f.tmp" && mv "$f.tmp" "$f"
case "$*" in *"${CLAUDE_FAIL_ON:-<never>}"*) exit 1 ;; esac
EOF
chmod +x "$STUBS/claude"

# run_install <config-dir> [VAR=value ...]
# Sets the globals STATUS, CALLS_OUT, STDOUT_OUT and STDERR_OUT.
run_install() {
    local dir="$1"; shift
    local calls="$WORK/calls" out="$WORK/stdout" err="$WORK/stderr"
    : > "$calls"
    STATUS=0
    env -i PATH="$STUBS:/usr/bin:/bin:$(dirname "$(command -v jq)")" CALLS="$calls" CLAUDE_CONFIG_DIR="$dir" "$@" \
        bash "$INSTALL" ${INSTALL_ARGS:+"$INSTALL_ARGS"} >"$out" 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDOUT_OUT="$(cat "$out")"
    STDERR_OUT="$(cat "$err")"
}

new_dir() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    cat > "$dir/settings.json"
    printf '%s' "$dir"
}

# --- tests ------------------------------------------------------------------
echo "install-claude-plugins.sh"

dir="$(new_dir basic <<'EOF'
{
  "theme": "dark",
  "enabledPlugins": {
    "one@alpha": true,
    "two@beta": true,
    "off@beta": false,
    "local@elsewhere": true
  },
  "extraKnownMarketplaces": {
    "alpha": { "source": { "source": "github", "repo": "example/alpha" } },
    "beta": { "source": { "source": "github", "repo": "example/beta" } }
  }
}
EOF
)"
cp "$dir/settings.json" "$WORK/basic.orig"
run_install "$dir"
assert_status 0 "succeeds on valid settings"
assert_eq "$CALLS_OUT" "claude plugin marketplace add example/alpha
claude plugin marketplace add example/beta
claude plugin install one@alpha
claude plugin install two@beta" "adds every marketplace, then every enabled plugin"
assert_contains "$STDOUT_OUT" "skipping local@elsewhere" "skips a plugin whose marketplace is not declared"
if cmp -s "$dir/settings.json" "$WORK/basic.orig"; then ok "restores settings.json byte for byte"; else bad "settings.json was left rewritten"; fi

INSTALL_ARGS=--update run_install "$dir"
assert_status 0 "succeeds with --update"
assert_eq "$CALLS_OUT" "claude plugin marketplace add example/alpha
claude plugin marketplace add example/beta
claude plugin marketplace update
claude plugin install one@alpha
claude plugin update one@alpha
claude plugin install two@beta
claude plugin update two@beta" "--update refreshes the marketplaces and updates each plugin"
assert_contains "$STDOUT_OUT" "skipping local@elsewhere" "--update still skips an undeclared marketplace"
if cmp -s "$dir/settings.json" "$WORK/basic.orig"; then ok "restores settings.json after --update"; else bad "settings.json was left rewritten after --update"; fi

INSTALL_ARGS=--bogus run_install "$dir"
assert_status 2 "rejects an unknown argument"

run_install "$dir" CLAUDE_FAIL_ON="plugin install one@alpha"
assert_status 1 "fails when a plugin cannot be installed"
if cmp -s "$dir/settings.json" "$WORK/basic.orig"; then ok "restores settings.json after a failure"; else bad "settings.json was left rewritten after a failure"; fi

run_install "$WORK/missing"
assert_status 1 "fails when settings.json is missing"
assert_contains "$STDERR_OUT" "settings.json" "names the missing settings"

# The shipped dotfile is the real input: guard the wiring itself.
mkdir -p "$WORK/repo"
cp "$REPO_ROOT/.claude/settings.json" "$WORK/repo/settings.json"
run_install "$WORK/repo"
assert_status 0 "installs from the repo's .claude/settings.json"
assert_contains "$CALLS_OUT" "claude plugin marketplace add anthropics/claude-plugins-official" "repo settings add the official marketplace"
assert_contains "$CALLS_OUT" "claude plugin install superpowers@claude-plugins-official" "repo settings install superpowers"
assert_contains "$CALLS_OUT" "claude plugin install ponytail@ponytail" "repo settings install ponytail"
assert_contains "$CALLS_OUT" "claude plugin install claude-hud@claude-hud" "repo settings install claude-hud"
assert_contains "$STDOUT_OUT" "skipping nono@always-further" "repo settings skip nono's local marketplace"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
