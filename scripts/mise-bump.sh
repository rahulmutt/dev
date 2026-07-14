#!/usr/bin/env bash
#
# Bump the pinned container toolchain in .config/mise/config.toml to the latest
# available releases, and render a markdown summary of what moved.
#
# Usage:
#   scripts/mise-bump.sh [--summary-out <file>]      # bump, then write the summary
#   scripts/mise-bump.sh --summary <before> <after>  # render a summary only
#
# The --summary form is a pure function over two config files -- it runs no
# mise and touches no network -- which is what scripts/tests/mise-bump.test.sh
# drives.
#
# Run daily by .github/workflows/mise-bump.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# The container toolchain. NOT the repo's root mise.toml, which pins the dev
# tooling (shellcheck) and is deliberately left alone.
CONFIG=".config/mise/config.toml"

# Load ONLY the container-toolchain config. Without this, mise also picks up the
# repo's root mise.toml and would bump the dev tooling (shellcheck) into the same
# PR. This is the same lever check.yaml pulls, pointed the other way.
export MISE_OVERRIDE_CONFIG_FILENAMES="$CONFIG"

# --bump keeps each entry's existing precision, and every entry is already an
# exact three-part version, so bumped entries stay exactly pinned. `mise upgrade`
# has no --pin flag (that belongs to `mise use`); MISE_PIN makes the exactness a
# guarantee rather than a coincidence.
export MISE_PIN=1

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
    echo "usage: $0 [--summary-out <file>] | --summary <before> <after>" >&2
    exit 2
}

# Bump every pin in $CONFIG to the latest available release.
#
# --minimum-release-age 0s takes releases the moment they land, rather than
# waiting out any configured quarantine: this repo's safety net is the devpod
# matrix that runs on the resulting PR, not a waiting period.
bump() {
    local summary_out="$1" before summary

    cd "$REPO_ROOT"

    before="$(mktemp)"
    # shellcheck disable=SC2064  # expand $before now: it is gone by trap time otherwise
    trap "rm -f '$before'" EXIT
    cp "$CONFIG" "$before"

    # A fresh CI runner has never trusted this config, and mise silently ignores
    # configs it does not trust.
    mise trust --yes "$CONFIG"
    mise upgrade --bump --yes --minimum-release-age 0s

    summary="$(render_summary "$before" "$CONFIG")"
    printf '%s\n' "$summary"
    if [ -n "$summary_out" ]; then
        printf '%s\n' "$summary" > "$summary_out"
    fi
}

main() {
    local summary_out=""

    case "${1:-}" in
        --summary)
            [ "$#" -eq 3 ] || usage
            render_summary "$2" "$3"
            return 0
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --summary-out)
                [ "$#" -ge 2 ] || usage
                summary_out="$2"
                shift 2
                ;;
            *)
                usage
                ;;
        esac
    done

    bump "$summary_out"
}

main "$@"
