#!/usr/bin/env bash
#
# codex-hook-hashes.sh — print or check Codex hook trust for installed plugins.
#
# Codex only runs a plugin hook once it is trusted, recorded in config.toml as
#
#   [hooks.state."<plugin>:<hooks file>:<event>:<i>:<j>"]
#   trusted_hash = "sha256:..."
#
# The hash covers the hook's entry in the plugin's hooks file (not the script it
# runs), so it is the same on every machine and can be pinned in the dotfile.
# When a plugin changes a hook's definition the pinned hash goes stale: codex
# reports the hook as "modified" and stops running it until it is re-trusted.
#
# Usage:
#   scripts/codex-hook-hashes.sh          # print the [hooks.state] block to paste into .codex/config.toml
#   scripts/codex-hook-hashes.sh --check  # exit 1, naming each hook, unless every hook is trusted
#
# Asks `codex app-server` (hooks/list) about $CODEX_HOME (default: ~/.codex).
# Admin-managed hooks are trusted by policy and skipped.

set -euo pipefail

mode=print
case "${1:-}" in
    "") ;;
    --check) mode=check ;;
    -h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

coproc APP { codex app-server 2>/dev/null; }

# await <id>: print the JSON-RPC message with that id, skipping notifications.
await() {
    local line
    while IFS= read -r -t 60 line <&"${APP[0]}"; do
        if [ "$(jq -r '.id // empty' <<<"$line")" = "$1" ]; then
            printf '%s\n' "$line"
            return
        fi
    done
    echo "codex-hook-hashes: no reply from codex app-server" >&2
    return 1
}

echo '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-hook-hashes","version":"0"}}}' >&"${APP[1]}"
await 1 >/dev/null
echo '{"method":"initialized"}' >&"${APP[1]}"
echo "{\"id\":2,\"method\":\"hooks/list\",\"params\":{\"cwds\":[\"$PWD\"]}}" >&"${APP[1]}"
reply="$(await 2)"
kill "$APP_PID" 2>/dev/null || true

if jq -e '.error' <<<"$reply" >/dev/null; then
    echo "codex-hook-hashes: hooks/list failed: $(jq -c '.error' <<<"$reply")" >&2
    exit 1
fi

hooks="$(jq -c '[.result.data[].hooks[] | select(.isManaged | not)] | unique_by(.key)' <<<"$reply")"

if [ "$mode" = print ]; then
    jq -r 'map("[hooks.state.\"\(.key)\"]\ntrusted_hash = \"\(.currentHash)\"") | join("\n\n")' <<<"$hooks"
    exit
fi

untrusted="$(jq -r '.[] | select(.trustStatus != "trusted") | "  \(.key) (\(.trustStatus))"' <<<"$hooks")"
if [ -n "$untrusted" ]; then
    printf 'codex hooks not trusted; refresh with scripts/codex-hook-hashes.sh:\n%s\n' "$untrusted" >&2
    exit 1
fi
echo "all $(jq length <<<"$hooks") codex hooks trusted"
