#!/usr/bin/env bash
#
# Bump the pinned container toolchain in .config/mise/config.toml to the latest
# available releases, and render a markdown summary of what moved.
#
# Usage:
#   scripts/mise-bump.sh --summary <before> <after>   # render a summary only
#
# The --summary form is a pure function over two config files -- it runs no
# mise and touches no network -- which is what scripts/tests/mise-bump.test.sh
# drives.

set -euo pipefail

# The container toolchain. NOT the repo's root mise.toml, which pins the dev
# tooling (shellcheck) and is deliberately left alone.
CONFIG=".config/mise/config.toml"

TAB="$(printf '\t')"

# Emit "<tool><TAB><version>" for every pin in the [tools] table.
#
# Scoped to that table on purpose: a quoted value anywhere else in the file
# (say, under [settings]) is a setting, not a tool, and must not show up in the
# PR body as though a tool had moved.
pins() {
    awk '/^\[tools\]/ { in_tools = 1; next } /^\[/ { in_tools = 0 } in_tools' "$1" |
        sed -nE 's/^[[:space:]]*"?([^"=[:space:]]+)"?[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1\t\2/p'
}

# Markdown table of every pin whose version differs between two configs.
# `join` needs both sides sorted on the join field, hence the sort.
render_summary() {
    local before="$1" after="$2" rows
    rows="$(join -t"$TAB" -j 1 \
        <(pins "$before" | sort -t"$TAB" -k1,1) \
        <(pins "$after" | sort -t"$TAB" -k1,1) |
        awk -F'\t' '$2 != $3 { printf "| `%s` | `%s` | `%s` |\n", $1, $2, $3 }')"

    if [ -z "$rows" ]; then
        echo "No tool updates available."
        return 0
    fi

    echo "\`mise upgrade --bump --minimum-release-age 0s\` found newer releases for the pinned toolchain in \`$CONFIG\`."
    echo
    echo "| Tool | From | To |"
    echo "| --- | --- | --- |"
    echo "$rows"
}

usage() {
    echo "usage: $0 --summary <before> <after>" >&2
    exit 2
}

main() {
    case "${1:-}" in
        --summary)
            [ "$#" -eq 3 ] || usage
            render_summary "$2" "$3"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
