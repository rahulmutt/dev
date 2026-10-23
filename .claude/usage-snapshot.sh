#!/usr/bin/env bash
#
# usage-snapshot.sh — write the claude.ai plan usage windows for claude-hud.
#
# Claude Code only hands the status line the 5-hour and 7-day windows; the
# per-model weekly windows (e.g. Fable) are only in the usage endpoint. This
# asks that endpoint with the existing Claude login and writes the snapshot
# claude-hud reads (display.externalUsagePath in plugins/claude-hud/config.json).
#
# Run in the background by statusline.sh when the snapshot is stale. Any
# failure (no login, expired token, network, an endpoint change) leaves the
# old snapshot alone and exits 0; claude-hud stops showing it once it is older
# than display.externalUsageFreshnessMs. The endpoint is undocumented.
#
# Usage:
#   usage-snapshot.sh [OUTPUT]   (default: ~/.cache/claude-hud/usage.json)
#
# Needs a file-based login ($CLAUDE_CONFIG_DIR/.credentials.json); on macOS the
# token is in the keychain, so this does nothing there.

set -uo pipefail

out="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-hud/usage.json}"
creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
url="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"

token="$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)" || exit 0
[ -n "$token" ] || exit 0

mkdir -p "$(dirname "$out")" || exit 0
umask 077
tmp="$(mktemp "$out.XXXXXX")" || exit 0
trap 'rm -f "$tmp"' EXIT

# The header goes in on stdin so the token never shows in `ps`.
body="$(printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --max-time 10 -H @- -H 'anthropic-beta: oauth-2025-04-20' "$url" 2>/dev/null)" || exit 0

jq '{
    updated_at: (now | todate),
    five_hour: {used_percentage: .five_hour.utilization, resets_at: .five_hour.resets_at},
    seven_day: {used_percentage: .seven_day.utilization, resets_at: .seven_day.resets_at},
    model_scoped: [.limits[]? | select(.kind == "weekly_scoped" and .scope.model.display_name != null)
        | {display_name: .scope.model.display_name, utilization: .percent, resets_at}]
}' <<<"$body" >"$tmp" 2>/dev/null || exit 0

# Only replace the snapshot with one that carries real windows.
jq -e '.five_hour.used_percentage != null or .seven_day.used_percentage != null' "$tmp" >/dev/null 2>&1 || exit 0
mv "$tmp" "$out"
