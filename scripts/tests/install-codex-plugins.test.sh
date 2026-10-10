#!/usr/bin/env bash
#
# Tests for scripts/install-codex-plugins.sh.
#
# `codex` is replaced with a stub that only records how it was called, so these
# tests never touch the network or a real Codex install.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install-codex-plugins.sh"

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
# Records each call; exits 1 when the call matches $CODEX_FAIL_ON.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/codex" <<'EOF'
#!/bin/sh
echo "codex $*" >> "$CALLS"
case "$*" in *"${CODEX_FAIL_ON:-<never>}"*) exit 1 ;; esac
EOF
chmod +x "$STUBS/codex"

# run_install <codex-home> [VAR=value ...]
# Sets the globals STATUS, CALLS_OUT and STDERR_OUT.
run_install() {
    local home="$1"; shift
    local calls="$WORK/calls" err="$WORK/stderr"
    : > "$calls"
    STATUS=0
    env -i PATH="$STUBS:/usr/bin:/bin" CALLS="$calls" CODEX_HOME="$home" "$@" \
        bash "$INSTALL" >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

new_home() {
    local home="$WORK/$1"
    mkdir -p "$home"
    cat > "$home/config.toml"
    printf '%s' "$home"
}

# --- tests ------------------------------------------------------------------
echo "install-codex-plugins.sh"

home="$(new_home basic <<'EOF'
model = "gpt-5.5"

[marketplaces.alpha]
source_type = "git"
source = "https://github.com/example/alpha.git"

[plugins."one@alpha"]
enabled = true

[marketplaces.beta]
source_type = "git"
source = "https://github.com/example/beta.git"

[plugins."two@beta"]
enabled = true

[plugins."off@beta"]
enabled = false
EOF
)"
run_install "$home"
assert_status 0 "succeeds on a valid config"
assert_eq "$CALLS_OUT" "codex plugin marketplace add https://github.com/example/alpha.git
codex plugin marketplace add https://github.com/example/beta.git
codex plugin add one@alpha
codex plugin add two@beta" "adds every marketplace, then every enabled plugin"

run_install "$home" CODEX_FAIL_ON="plugin add one@alpha"
assert_status 1 "fails when a plugin cannot be installed"

run_install "$WORK/missing"
assert_status 1 "fails when config.toml is missing"
assert_contains "$STDERR_OUT" "config.toml" "names the missing config"

# The shipped dotfile is the real input: guard the wiring itself.
mkdir -p "$WORK/repo"
cp "$REPO_ROOT/.codex/config.toml" "$WORK/repo/config.toml"
run_install "$WORK/repo"
assert_status 0 "installs from the repo's .codex/config.toml"
assert_contains "$CALLS_OUT" "codex plugin add superpowers@superpowers-dev" "repo config installs superpowers"
assert_contains "$CALLS_OUT" "codex plugin add ponytail@ponytail" "repo config installs ponytail"
assert_contains "$CALLS_OUT" "codex plugin add devkit@devkit-marketplace" "repo config installs devkit"
assert_contains "$CALLS_OUT" "codex plugin add impeccable@impeccable" "repo config installs impeccable"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
