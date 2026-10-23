#!/usr/bin/env bash
#
# install-pi-packages.sh — install the pi packages declared in settings.json.
#
# pi installs missing packages on first launch, which clones and npm-installs
# every one before pi is usable; this does it ahead of time. `pi install` runs
# per source rather than `pi update --extensions`, which skips pinned
# (@version) sources even when they're missing; it leaves settings.json as is.
#
# With --update, also runs `pi update --extensions` afterwards, bringing every
# unpinned package to its latest release (pinned ones stay put).
#
# Usage:
#   scripts/install-pi-packages.sh [--update]
#
# Reads ~/.pi/agent/settings.json.

set -euo pipefail

update=0
case "${1:-}" in
    --update) update=1 ;;
    "") ;;
    *) echo "install-pi-packages: unknown argument: $1" >&2; exit 2 ;;
esac

settings="$HOME/.pi/agent/settings.json"

if [ ! -f "$settings" ]; then
    echo "install-pi-packages: no settings at $settings" >&2
    exit 1
fi

for src in $(jq -r '.packages // [] | .[] | strings' "$settings"); do
    pi install "$src" </dev/null
done

if [ "$update" -eq 1 ]; then
    pi update --extensions </dev/null
fi
