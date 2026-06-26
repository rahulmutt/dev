#!/bin/sh
#
# install.sh — one-line dotfiles installer.
#
# Clones this repo into a temporary directory, syncs its dotfiles into your
# home directory (backing up anything it replaces), then removes the clone.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rahulmutt/dev/main/scripts/install.sh | sh
#
# Pass arguments through to the sync step after `-s --`, e.g. preview only:
#   curl -fsSL .../install.sh | sh -s -- --dry-run
#   curl -fsSL .../install.sh | sh -s -- --yes
#
# Overridable via environment:
#   DOTFILES_REPO    git URL to clone   (default: https://github.com/rahulmutt/dev.git)
#   DOTFILES_BRANCH  branch to clone    (default: main)

set -eu

REPO_URL="${DOTFILES_REPO:-https://github.com/rahulmutt/dev.git}"
REPO_BRANCH="${DOTFILES_BRANCH:-main}"

command -v git  >/dev/null 2>&1 || { echo "install.sh: git is required"  >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "install.sh: bash is required" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo "Cloning $REPO_URL ($REPO_BRANCH) ..."
git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP_DIR/dev"

# Hand off to the full sync script in the fresh clone. The EXIT trap above
# removes the clone afterwards, whether the sync succeeds or fails.
bash "$TMP_DIR/dev/scripts/sync-dotfiles.sh" "$@"
