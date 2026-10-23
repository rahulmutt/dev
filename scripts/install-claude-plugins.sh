#!/usr/bin/env bash
#
# install-claude-plugins.sh — install the Claude plugins declared in settings.json.
#
# Declaring plugins in ~/.claude/settings.json is not enough on its own: a fresh
# HOME has only the built-in Anthropic Directory marketplace, so nothing is
# installed (and the claude-hud status line is blank) until Claude fetches each
# marketplace and plugin.
#
# settings.json stays the single list of plugins. This script adds every
# GitHub-sourced `extraKnownMarketplaces` entry, then installs every
# `enabledPlugins` entry set to true whose marketplace is declared there.
# Plugins from other marketplaces (nono's always-further, which nono wires up
# locally) are skipped. Both commands are idempotent; claude rewrites
# settings.json as it goes (same content, reordered keys), so the file is put
# back byte for byte afterwards. Safe to re-run (e.g. after
# scripts/sync-dotfiles.sh).
#
# Usage:
#   scripts/install-claude-plugins.sh
#
# Reads $CLAUDE_CONFIG_DIR/settings.json (default: ~/.claude/settings.json).

set -euo pipefail

settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

if [ ! -f "$settings" ]; then
    echo "install-claude-plugins: no settings at $settings" >&2
    exit 1
fi

saved="$(mktemp)"
cp "$settings" "$saved"
trap 'cp "$saved" "$settings"; rm -f "$saved"' EXIT

declared="$(jq -r '.extraKnownMarketplaces // {} | keys[]' "$saved")"

for repo in $(jq -r '.extraKnownMarketplaces // {} | .[] | .source | select(.source == "github") | .repo' "$saved"); do
    claude plugin marketplace add "$repo" </dev/null
done

for id in $(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$saved"); do
    if ! printf '%s\n' "$declared" | grep -qxF "${id##*@}"; then
        echo "install-claude-plugins: skipping $id (marketplace not in extraKnownMarketplaces)"
        continue
    fi
    claude plugin install "$id" </dev/null
done
