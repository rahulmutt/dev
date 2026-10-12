#!/usr/bin/env bash
#
# Bump the environment: the pinned container toolchain in .config/mise/config.toml
# and Codex hook trust in .codex/config.toml, and render a markdown summary.
#
# Usage:
#   scripts/env-bump.sh [--summary-out <file>]           # bump, then write the summary
#   scripts/env-bump.sh --summary <before> <after>       # render a summary only
#   scripts/env-bump.sh --partial-bump <mise-stderr>     # was the bump partial?
#   scripts/env-bump.sh --rewrite-hooks <config> <block>  # replace codex hook trust tables
#   scripts/env-bump.sh --hooks-summary <before> <after>  # render the hook trust changes
#
# The --summary and --partial-bump forms are pure functions -- over two config
# files, and over a captured stderr log, respectively -- that run no mise and
# touch no network, which is what scripts/tests/env-bump.test.sh drives.
#
# Run daily by .github/workflows/env-bump.yaml.

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

# Codex config whose [hooks.state] tables pin the trusted hash of each plugin
# hook. Only those tables are rewritten; the rest of the file is left alone.
CODEX_CONFIG=".codex/config.toml"

# --bump keeps each entry's existing precision, and every entry is already an
# exact three-part version, so bumped entries stay exactly pinned. `mise upgrade`
# has no --pin flag (that belongs to `mise use`); MISE_PIN makes the exactness a
# guarantee rather than a coincidence.
export MISE_PIN=1

# Tools that other pins declare as an install dependency. Bumped in their own
# pass, before everything else -- see bump() for why.
DEPENDENCY_TOOLS=(node)

TAB="$(printf '\t')"

# Emit "<tool><TAB><version>" for every pin in the [tools] table.
#
# Scoped to that table on purpose: a quoted value anywhere else in the file
# (say, under [settings]) is a setting, not a tool, and must not show up in the
# PR body as though a tool had moved.
#
# Assumes every entry is a plain quoted string ('name = "1.2.3"'). mise also
# accepts an inline-table form ('node = { version = "26.5.0" }'), which this
# regex does not match -- such an entry would silently vanish from the PR
# table instead of appearing as a row. All 26 current pins are plain strings,
# so this is not a live bug, just a limit worth knowing about if mise ever
# rewrites one of them with options.
pins() {
    awk '/^\[tools\]/ { in_tools = 1; next } /^\[/ { in_tools = 0 } in_tools' "$1" |
        sed -nE 's/^[[:space:]]*"?([^"=[:space:]]+)"?[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1\t\2/p'
}

# True if mise's captured stderr shows a tool failed to resolve during a
# bump. `mise upgrade --bump` does not turn that into a nonzero exit -- it
# warns on stderr, drops the tool from the plan, and happily bumps the rest
# (verified empirically). Pure over the given file -- invokes no mise -- so
# it is unit-testable offline via `--partial-bump <file>`
# (scripts/tests/env-bump.test.sh).
tool_resolution_failed() {
    grep -qF 'Failed to resolve tool version list' "$1"
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

# Print <config> with every [hooks.state."…"] table removed and trailing blank
# lines trimmed, then -- if <block> is non-empty -- a blank line and <block>.
# Pure over the two files.
rewrite_hooks() {
    awk '
        /^\[hooks\.state\./ { skip = 1; next }
        /^\[/ { skip = 0 }
        skip { next }
        { lines[++n] = $0 }
        END {
            while (n > 0 && lines[n] == "") n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$1"
    if [ -s "$2" ]; then
        echo
        cat "$2"
    fi
}

# Emit "<hook key><TAB><trusted hash>" for every [hooks.state] table.
hook_pins() {
    awk '
        /^\[hooks\.state\."/ {
            key = $0
            sub(/^\[hooks\.state\."/, "", key)
            sub(/"\][[:space:]]*$/, "", key)
            next
        }
        /^\[/ { key = "" }
        key != "" && /^trusted_hash[[:space:]]*=/ {
            hash = $0
            sub(/^[^"]*"/, "", hash)
            sub(/".*$/, "", hash)
            print key "\t" hash
            key = ""
        }
    ' "$1"
}

# Markdown list of hooks added, changed or removed between two configs, or
# nothing when the trusted set is unchanged. FILENAME == ARGV[1] rather than
# NR == FNR, so an empty before-config is not mistaken for the after-config.
render_hooks_summary() {
    local rows
    rows="$(awk -F'\t' '
        FILENAME == ARGV[1] { before[$1] = $2; next }
        { after[$1] = $2 }
        END {
            for (k in after) {
                if (!(k in before)) print "added\t" k
                else if (before[k] != after[k]) print "changed\t" k
            }
            for (k in before) if (!(k in after)) print "removed\t" k
        }
    ' <(hook_pins "$1") <(hook_pins "$2") |
        sort -t"$TAB" -k2,2 |
        awk -F'\t' '{ printf "- %s `%s`\n", $1, $2 }')"

    [ -n "$rows" ] || return 0

    echo "### Codex hook trust"
    echo
    echo "Re-trusted with \`scripts/codex-hook-hashes.sh\` after installing the plugins declared in \`$CODEX_CONFIG\`:"
    echo
    echo "$rows"
}

usage() {
    echo "usage: $0 [--summary-out <file>] | --summary <before> <after> | --partial-bump <stderr-file> | --rewrite-hooks <config> <block> | --hooks-summary <before> <after>" >&2
    exit 2
}

# Bump every pin in $CONFIG to the latest available release.
#
# --minimum-release-age 0s takes releases the moment they land, rather than
# waiting out any configured quarantine: this repo's safety net is the devpod
# matrix that runs on the resulting PR, not a waiting period.
#
# The bump runs in two passes, dependencies first. The npm: tools declare
# node as an install dependency, and mise resolves that dependency against
# the config as it stands when the plan is built. In a single pass on a day
# node moves, the plan installs the NEW node but the npm: tools still ask for
# the OLD node -- which was never installed on a fresh runner (mise-action runs
# with install: false) -- and since mise 2026.9.1 that is a hard error rather
# than a fall-through to PATH. Bumping node alone first rewrites its pin and
# installs the new version, so the second pass sees a dependency that is both
# current and present.
bump() {
    local summary_out="$1" before stderr_log summary

    cd "$REPO_ROOT"

    before="$(mktemp)"
    stderr_log="$(mktemp)"
    # shellcheck disable=SC2064  # expand now: both vars are gone by trap time otherwise
    trap "rm -f '$before' '$stderr_log'" EXIT
    cp "$CONFIG" "$before"

    # A fresh CI runner has never trusted this config, and mise treats an
    # untrusted config as a hard error, not a silent skip.
    mise trust --yes "$CONFIG"

    # Capture mise's stderr to a file so tool_resolution_failed can inspect it
    # afterward, but also copy it to this job's own stderr (after the run
    # completes, so the copy is not racing mise's writes) so an operator
    # watching the Actions log still sees everything mise printed. Both passes
    # append to the same log so the partial-bump check covers the whole bump.
    : >"$stderr_log"
    if ! mise upgrade --bump --yes --minimum-release-age 0s "${DEPENDENCY_TOOLS[@]}" 2>>"$stderr_log" ||
        ! mise upgrade --bump --yes --minimum-release-age 0s 2>>"$stderr_log"; then
        cat "$stderr_log" >&2
        echo "env-bump: mise upgrade exited nonzero" >&2
        cp "$before" "$CONFIG"  # A failed run must leave no changes behind
        exit 1
    fi
    cat "$stderr_log" >&2

    # A partial bump (one tool failed to resolve, the rest silently moved on)
    # must fail loudly rather than open a PR that looks like a clean bump.
    # No summary is written below, so no PR is opened; this is meant to be a
    # noisy daily failure until a human removes or fixes the dead tool.
    if tool_resolution_failed "$stderr_log"; then
        echo "env-bump: mise failed to resolve one or more pinned tools (see stderr above)." >&2
        echo "env-bump: refusing to open a PR for a partial bump." >&2
        cp "$before" "$CONFIG"  # Refusal must leave no changes behind
        exit 1
    fi

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
        --partial-bump)
            [ "$#" -eq 2 ] || usage
            if tool_resolution_failed "$2"; then
                return 0
            else
                return 1
            fi
            ;;
        --rewrite-hooks)
            [ "$#" -eq 3 ] || usage
            rewrite_hooks "$2" "$3"
            return 0
            ;;
        --hooks-summary)
            [ "$#" -eq 3 ] || usage
            render_hooks_summary "$2" "$3"
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
