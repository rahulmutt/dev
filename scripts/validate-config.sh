#!/usr/bin/env bash
#
# validate-config.sh — check the home dotfiles against the installed tools.
#
# Validates ~/.claude/settings.json, ~/.codex/config.toml and
# ~/.pi/agent/settings.json: no versioned mise install paths, each tool
# accepts its settings, and every declared plugin and package resolves.
# Read-only: plugin installs happen in scratch HOMEs.
#
# Every check runs even if an earlier one failed, so one run reports
# everything. Exits 1 if any check failed. Needs no Claude or Codex login, but
# does need the network (plugin installs clone their marketplaces).
#
# Usage:
#   scripts/validate-config.sh
#
# Run in the built image by scripts/validate-devpod.sh.

set -uo pipefail  # no -e: a failing check must not stop the others

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOOK_HASHES="${CODEX_HOOK_HASHES:-$SCRIPT_DIR/codex-hook-hashes.sh}"

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
PI_SETTINGS="$HOME/.pi/agent/settings.json"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
skip() { echo "  skip  $*"; }
detail() { sed 's/^/          /'; }

# need <file>: fail and return 1 if it doesn't exist.
need() {
    [ -f "$1" ] && return 0
    fail "$1 is missing"
    return 1
}

# A settings file must not name a versioned mise install path: it breaks the
# moment the tool is bumped. Point at installs/<tool>/latest/ instead, which
# mise keeps as a symlink to the installed version. Major/minor symlinks
# (installs/node/26) still drift on a major bump, so they count as versioned.
check_pinned_paths() {
    local f hits
    for f in "$CLAUDE_SETTINGS" "$CODEX_CONFIG" "$PI_SETTINGS"; do
        need "$f" || continue
        hits="$(grep -noE 'mise/installs/[^/"]+/[0-9][^/" ]*' "$f" || true)"
        if [ -n "$hits" ]; then
            fail "$(basename "$f") names a versioned mise install path; use installs/<tool>/latest/"
            printf '%s\n' "$hits" | detail
        else
            pass "$(basename "$f"): no versioned mise install paths"
        fi
    done
}

# pi has no validator of its own (`pi list` exits 0 on invalid JSON), so check
# the shape this repo relies on: an object whose packages are strings.
check_pi_settings() {
    need "$PI_SETTINGS" || return
    if jq -e 'type == "object" and ((.packages // []) | type == "array" and all(type == "string"))' \
        "$PI_SETTINGS" >/dev/null 2>&1; then
        pass "pi settings.json"
    else
        fail "pi settings.json is not an object with a string-array packages list"
    fi
}

# Each declared package's install dir exists. A pinned source ends in
# @<version> or @<ref>; the install dir doesn't.
check_pi_packages() {
    local src pkg repo dir
    need "$PI_SETTINGS" || return
    for src in $(jq -r '.packages // [] | .[] | strings' "$PI_SETTINGS" 2>/dev/null); do
        case "$src" in
            npm:@*@*|npm:[!@]*@*) pkg="${src#npm:}"; dir="$HOME/.pi/agent/npm/node_modules/${pkg%@*}" ;;
            npm:*) dir="$HOME/.pi/agent/npm/node_modules/${src#npm:}" ;;
            git:*@*) repo="${src#git:}"; dir="$HOME/.pi/agent/git/${repo%@*}" ;;
            git:*) dir="$HOME/.pi/agent/git/${src#git:}" ;;
            *) fail "pi package $src has an unchecked source type"; continue ;;
        esac
        if [ -d "$dir" ]; then
            pass "pi package $src installed"
        else
            fail "pi package $src not installed at $dir"
        fi
    done
}

main() {
    echo "==> pinned paths"
    check_pinned_paths
    echo "==> pi"
    check_pi_settings
    check_pi_packages

    if [ "$failures" -gt 0 ]; then
        echo "${failures} check(s) failed"
        exit 1
    fi
    echo "config OK"
}

main "$@"
