#!/usr/bin/env bash
#
# sync-dotfiles.sh — safely sync the dotfiles in this repo into your home dir.
#
# The repo is the source of truth. For every git-tracked file under the known
# dotfile roots (.claude, .codex, .config, .pi, .tmux.conf) the script compares
# the SHA-256 of the repo copy against the SHA-256 of the file already on your
# system. When they differ (or the target is missing) it copies the repo
# version over — but first it backs up whatever was there into a timestamped
# backup directory, so nothing is ever lost.
#
# Because it enumerates *git-tracked* files, anything ignored by .gitignore
# (e.g. .pi/agent/auth.json, installed packages) is never touched.
#
# Usage:
#   scripts/sync-dotfiles.sh [--dry-run] [--verbose] [--home DIR] [--yes]
#
#   --dry-run     Show what would change; modify nothing.
#   --verbose, -v Show a diff of every changed/new file and list unchanged ones.
#   --home DIR    Target directory to sync into (default: $HOME).
#   --yes, -y     Don't prompt for confirmation before applying changes.
#   --help, -h    Show this help.
#
# Tip: combine --dry-run --verbose to preview the exact diffs without touching
# anything.

set -euo pipefail

# --- locate the repo root (one level up from this script) -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Dotfile roots that map into the home directory. Everything else in the repo
# (base/, ngrok/, scripts/, .devcontainer/, .github/, README.md, ...) is repo
# infrastructure and is intentionally left out.
DOTFILE_ROOTS=(.claude .codex .config .pi .tmux.conf)

# --- args -------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
HOME_DIR="$HOME"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//; $d'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        --home) HOME_DIR="${2:?--home needs a directory}"; shift ;;
        --home=*) HOME_DIR="${1#*=}" ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Fail fast if anything we shell out to is missing, reporting all of them at
# once rather than blowing up partway through.
require_cmds() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "${0##*/}: missing required command(s): ${missing[*]}" >&2
        exit 1
    fi
}

require_cmds git sha256sum sed cut date cp mkdir dirname

HOME_DIR="$(cd -- "$HOME_DIR" 2>/dev/null && pwd || echo "$HOME_DIR")"

# --- colors (only when stdout is a tty) -------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

hash_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Print an indented unified diff from the current target ($1) to the repo
# version ($2). Uses `git diff --no-index` for colorized output that also
# handles binary files gracefully ("Binary files differ"). Pass /dev/null as
# $1 to show a new file as all-additions.
show_diff() {
    local old="$1" new="$2" color="--color=never"
    [ -n "$C_RESET" ] && color="--color=always"
    git --no-pager diff --no-index "$color" -- "$old" "$new" 2>/dev/null \
        | sed 's/^/    /' || true
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
# Backups are written next to each original as <file>.bak.<timestamp>.
BACKUP_SUFFIX=".bak.$TIMESTAMP"

echo "${C_BOLD}Syncing dotfiles${C_RESET}"
echo "  source : $REPO_ROOT"
echo "  target : $HOME_DIR"
[ "$DRY_RUN" -eq 1 ] && echo "  ${C_YELLOW}mode   : dry-run (no changes will be made)${C_RESET}"
echo

# --- collect the tracked file list ------------------------------------------
# git ls-files respects .gitignore, so ignored secrets are excluded by design.
mapfile -t FILES < <(git -C "$REPO_ROOT" ls-files -- "${DOTFILE_ROOTS[@]}")

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No tracked dotfiles found under: ${DOTFILE_ROOTS[*]}" >&2
    exit 1
fi

# --- first pass: figure out what would change -------------------------------
declare -a TO_NEW=() TO_UPDATE=() TO_SAME=()
for rel in "${FILES[@]}"; do
    src="$REPO_ROOT/$rel"
    dst="$HOME_DIR/$rel"
    [ -f "$src" ] || continue   # skip e.g. submodule gitlinks
    if [ ! -e "$dst" ]; then
        TO_NEW+=("$rel")
    elif [ "$(hash_of "$src")" != "$(hash_of "$dst")" ]; then
        TO_UPDATE+=("$rel")
    else
        TO_SAME+=("$rel")
    fi
done

for rel in "${TO_NEW[@]:-}"; do
    [ -n "$rel" ] || continue
    echo "  ${C_GREEN}new${C_RESET}     $rel"
    [ "$VERBOSE" -eq 1 ] && show_diff /dev/null "$REPO_ROOT/$rel"
done
for rel in "${TO_UPDATE[@]:-}"; do
    [ -n "$rel" ] || continue
    echo "  ${C_YELLOW}changed${C_RESET} $rel"
    [ "$VERBOSE" -eq 1 ] && show_diff "$HOME_DIR/$rel" "$REPO_ROOT/$rel"
done
if [ "$VERBOSE" -eq 1 ]; then
    for rel in "${TO_SAME[@]:-}"; do
        [ -n "$rel" ] && echo "  ${C_DIM}ok${C_RESET}      $rel"
    done
fi

echo
echo "${C_DIM}${#TO_SAME[@]} file(s) already up to date.${C_RESET}"
printf '%s\n' "${C_BOLD}${#TO_NEW[@]} new, ${#TO_UPDATE[@]} to update, will back up ${#TO_UPDATE[@]} existing file(s).${C_RESET}"

if [ "${#TO_NEW[@]}" -eq 0 ] && [ "${#TO_UPDATE[@]}" -eq 0 ]; then
    echo "${C_GREEN}Everything is already in sync.${C_RESET}"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "${C_YELLOW}Dry run — nothing was changed.${C_RESET}"
    exit 0
fi

# --- confirm ----------------------------------------------------------------
# Read the answer from the controlling terminal so confirmation still works when
# this script is piped to a shell (e.g. via the curl | bash installer), where
# stdin is the script text rather than the keyboard.
if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    if [ -r /dev/tty ]; then
        printf 'Proceed? Each replaced file is backed up next to it as <file>%s [y/N] ' "$BACKUP_SUFFIX"
        read -r reply </dev/tty
    else
        echo "${C_YELLOW}No terminal available for confirmation.${C_RESET}" >&2
        echo "Re-run with --yes to apply non-interactively." >&2
        exit 1
    fi
    case "$reply" in
        y|Y|yes|Yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# --- second pass: apply -----------------------------------------------------
copied=0; updated=0; backed_up=0
apply_one() {
    local rel="$1" is_update="$2"
    local src="$REPO_ROOT/$rel" dst="$HOME_DIR/$rel"

    if [ "$is_update" -eq 1 ] && [ -e "$dst" ]; then
        cp -a -- "$dst" "${dst}${BACKUP_SUFFIX}"
        backed_up=$((backed_up + 1))
    fi

    mkdir -p "$(dirname -- "$dst")"
    cp -af -- "$src" "$dst"
}

for rel in "${TO_NEW[@]:-}";    do [ -n "$rel" ] && { apply_one "$rel" 0; copied=$((copied + 1)); }; done
for rel in "${TO_UPDATE[@]:-}"; do [ -n "$rel" ] && { apply_one "$rel" 1; updated=$((updated + 1)); }; done

echo
echo "${C_GREEN}${C_BOLD}Done.${C_RESET}"
echo "  ${copied} new file(s) copied"
echo "  ${updated} file(s) updated"
if [ "$backed_up" -gt 0 ]; then
    echo "  ${backed_up} file(s) backed up next to the originals as ${C_BLUE}<file>${BACKUP_SUFFIX}${C_RESET}"
fi
