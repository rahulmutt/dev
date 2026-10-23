#!/usr/bin/env bash
#
# statusline.sh — Claude Code status line: runs the newest installed claude-hud.
#
# Wired up by statusLine.command in settings.json. Claude pipes the session
# JSON to stdin, which is passed straight through to claude-hud.

# claude-hud sizes itself from $COLUMNS, which the status line command doesn't
# get reliably: fall back to the tty, then 120. Leave a 4-column margin.
cols="${COLUMNS:-}"
case "$cols" in "" | *[!0-9]*) cols="$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')" ;; esac
case "$cols" in "" | *[!0-9]*) cols=120 ;; esac
export COLUMNS=$((cols > 4 ? cols - 4 : 1))

# Plugin updates leave old versions in the cache, so pick the highest semver.
plugin_dir="$(
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/ |
        awk -F/ '{ print $(NF-1) "\t" $0 }' |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+[[:space:]]' |
        sort -t. -k1,1n -k2,2n -k3,3n -k4,4n |
        tail -1 |
        cut -f2-
)"
[ -n "$plugin_dir" ] || exit 0  # claude-hud not installed: show no status line

# bun by its mise `latest` symlink, not the shim: the shim resolves the version
# from the current project's mise config, which may not pin bun at all.
# --env-file /dev/null keeps bun from loading the project's .env files.
exec "${MISE_DATA_DIR:-$HOME/.local/share/mise}/installs/bun/latest/bin/bun" \
    --env-file /dev/null "${plugin_dir}src/index.ts"
