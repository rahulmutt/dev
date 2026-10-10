#!/usr/bin/env bash
#
# install-codex-plugins.sh — install the Codex plugins declared in config.toml.
#
# Declaring a marketplace and plugin in ~/.codex/config.toml is not enough on
# its own: Codex reads plugins from a fetched marketplace snapshot and a plugin
# cache, and only `codex plugin marketplace add` / `codex plugin add` create
# those. Without them `codex plugin list` fails with "marketplace root does not
# contain a supported manifest".
#
# config.toml stays the single list of plugins. This script adds every
# `[marketplaces.*]` source, then every `[plugins."<id>"]` with
# `enabled = true`. Both commands are idempotent and leave config.toml as is,
# so it is safe to re-run (e.g. after scripts/sync-dotfiles.sh).
#
# Usage:
#   scripts/install-codex-plugins.sh
#
# Reads $CODEX_HOME/config.toml (default: ~/.codex/config.toml).

set -euo pipefail

config="${CODEX_HOME:-$HOME/.codex}/config.toml"

if [ ! -f "$config" ]; then
    echo "install-codex-plugins: no config at $config" >&2
    exit 1
fi

# Prints "marketplace <source>" and "plugin <id>" lines, marketplaces first,
# since a plugin can only be added once its marketplace is.
parse() {
    awk '
        /^\[/ { section = $0; plugin = "" }
        /^\[plugins\."[^"]+"\]/ {
            plugin = $0
            sub(/^\[plugins\."/, "", plugin)
            sub(/"\].*$/, "", plugin)
        }
        section ~ /^\[marketplaces\./ && /^source[ \t]*=/ {
            src = $0
            sub(/^source[ \t]*=[ \t]*"/, "", src)
            sub(/".*$/, "", src)
            print "marketplace " src
        }
        plugin != "" && /^enabled[ \t]*=[ \t]*true/ { plugins = plugins "plugin " plugin "\n" }
        END { printf "%s", plugins }
    ' "$config"
}

while read -r kind value; do
    case "$kind" in
        marketplace) codex plugin marketplace add "$value" ;;
        plugin) codex plugin add "$value" ;;
    esac
done < <(parse)
