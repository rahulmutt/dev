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

# A fresh HOME has only the built-in Anthropic Directory, so the official
# marketplace must be added before its plugins will install.
OFFICIAL_MARKETPLACE="claude-plugins-official"
OFFICIAL_MARKETPLACE_REPO="anthropics/claude-plugins-official"

# Marketplaces another tool wires up locally, not installable from GitHub:
# nono's packs (always-further/nono-packs) set up always-further as a local
# directory marketplace. Plugins from these are skipped by name.
EXTERNAL_MARKETPLACES=(always-further)

# Resolve claude now, while HOME is the real one. On PATH it is a mise shim,
# which finds its version through $HOME/.config/mise, and the checks below
# swap HOME for a scratch dir, so a bare `claude` there has no version set.
CLAUDE_BIN="$(mise which claude 2>/dev/null || command -v claude || echo claude)"

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
            fail "${f#"$HOME"/} names a versioned mise install path; use installs/<tool>/latest/"
            printf '%s\n' "$hits" | detail
        else
            pass "${f#"$HOME"/}: no versioned mise install paths"
        fi
    done
}

# claude_doctor <home>: print `claude doctor` output for that HOME. Run from a
# scratch dir so no project settings are mixed in. It exits 0 even when it
# finds invalid settings, so callers match its output.
claude_doctor() {
    local dir
    dir="$(mktemp -d -p "$SCRATCH")"
    (cd "$dir" && HOME="$1" "$CLAUDE_BIN" doctor </dev/null 2>&1) || true
}

# Claude validates settings against its own schema, for the version installed.
# The canary guards the output match: if a claude bump rewords "Invalid
# settings", the canary stops matching and this fails instead of passing
# forever.
check_claude_settings() {
    local canary out
    need "$CLAUDE_SETTINGS" || return

    canary="$SCRATCH/claude-canary"
    mkdir -p "$canary/.claude"
    echo '{"permissions": {"defaultMode": "notAMode"}}' >"$canary/.claude/settings.json"
    if ! claude_doctor "$canary" | grep -qF 'Invalid settings'; then
        fail "claude doctor did not report a known-invalid settings file (detection broken)"
        return
    fi

    out="$(claude_doctor "$HOME")"
    if printf '%s\n' "$out" | grep -qF 'Invalid settings'; then
        fail "claude rejects settings.json"
        printf '%s\n' "$out" | sed -n '/Invalid settings/,/^$/p' | detail
    else
        pass "claude accepts settings.json"
    fi
}

# Every enabled plugin installs, in a scratch HOME holding a copy of the
# settings, so the real ~/.claude is never touched.
check_claude_plugins() {
    local home out repo id market declared
    need "$CLAUDE_SETTINGS" || return

    home="$SCRATCH/claude-plugins"
    mkdir -p "$home/.claude"
    cp "$CLAUDE_SETTINGS" "$home/.claude/settings.json"

    for repo in "$OFFICIAL_MARKETPLACE_REPO" $(jq -r '.extraKnownMarketplaces // {} | .[] | .source | select(.source == "github") | .repo' "$CLAUDE_SETTINGS"); do
        if out="$(cd "$home" && HOME="$home" "$CLAUDE_BIN" plugin marketplace add "$repo" </dev/null 2>&1)"; then
            pass "claude marketplace $repo"
        else
            fail "claude marketplace $repo"
            printf '%s\n' "$out" | detail
        fi
    done

    declared="$(jq -r '.extraKnownMarketplaces // {} | keys[]' "$CLAUDE_SETTINGS"; echo "$OFFICIAL_MARKETPLACE")"
    for id in $(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$CLAUDE_SETTINGS"); do
        market="${id##*@}"
        if printf '%s\n' "${EXTERNAL_MARKETPLACES[@]}" | grep -qxF "$market"; then
            skip "claude plugin $id (marketplace $market is wired locally)"
            continue
        fi
        if ! printf '%s\n' "$declared" | grep -qxF "$market"; then
            fail "claude plugin $id: marketplace $market is not declared in extraKnownMarketplaces"
            continue
        fi
        if out="$(cd "$home" && HOME="$home" "$CLAUDE_BIN" plugin install "$id" </dev/null 2>&1)"; then
            pass "claude plugin $id"
        else
            fail "claude plugin $id"
            printf '%s\n' "$out" | detail
        fi
    done
}

# Codex validates config.toml as it loads it; `codex doctor --json` reports
# that as checks["config.load"], with unrecognized keys as a warning. Its exit
# status is 1 without a login, so only the report is used. A missing check or
# unparseable report fails rather than passing silently.
check_codex_config() {
    local report status
    need "$CODEX_CONFIG" || return
    report="$(cd "$SCRATCH" && codex doctor --json </dev/null 2>/dev/null)"
    status="$(jq -r '.checks["config.load"].status // "missing"' <<<"$report" 2>/dev/null)" || status=unparseable
    if [ "$status" = ok ]; then
        pass "codex accepts config.toml"
    else
        fail "codex config.load is $status"
        jq -r '.checks["config.load"] // {} | .summary // empty, (.. | strings | select(test("unrecognized|ignored")))' \
            <<<"$report" 2>/dev/null | sort -u | detail
    fi
}

# Print each [plugins."<id>"] in $CODEX_CONFIG with enabled = true.
codex_enabled_plugins() {
    awk '
        /^\[/ { id = "" }
        /^\[plugins\."[^"]+"\]/ {
            id = $0
            sub(/^\[plugins\."/, "", id)
            sub(/"\].*$/, "", id)
        }
        id != "" && /^enabled[ \t]*=[ \t]*true/ { print id }
    ' "$CODEX_CONFIG"
}

check_codex_plugins() {
    local list id
    need "$CODEX_CONFIG" || return
    list="$(cd "$SCRATCH" && codex plugin list 2>&1 || true)"
    for id in $(codex_enabled_plugins); do
        if printf '%s\n' "$list" | grep -E "^$id +installed, enabled" >/dev/null; then
            pass "codex plugin $id installed"
        else
            fail "codex plugin $id not installed, enabled"
        fi
    done
}

# Pinned trust hashes go stale when a plugin changes a hook; codex then
# silently stops running it. env-bump refreshes them daily.
check_codex_hooks() {
    local out
    need "$CODEX_CONFIG" || return
    if out="$(cd "$SCRATCH" && bash "$CODEX_HOOK_HASHES" --check 2>&1)"; then
        pass "codex hook trust ($out)"
    else
        fail "codex hook trust"
        printf '%s\n' "$out" | detail
    fi
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
    echo "==> claude"
    check_claude_settings
    check_claude_plugins
    echo "==> codex"
    check_codex_config
    check_codex_plugins
    check_codex_hooks
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
