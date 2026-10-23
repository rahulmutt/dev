#!/usr/bin/env bash
#
# env-update — update mise, the dotfiles, the toolchain and the agent plugins,
# then run a command.
#
#   env-update                  # update, then exit
#   env-update claude --resume  # update, then exec `claude --resume`
#
# In order:
#   1. mise self-update
#   2. clone the dotfiles repo and sync its dotfiles (sync-dotfiles.sh, which
#      shows each change and asks before applying it)
#   3. mise upgrade --interactive --bump
#   4. install and update the Claude, Codex and pi plugins the (synced)
#      dotfiles declare, for each of those tools that is installed
#   5. check Codex hook trust: a plugin updated past what the repo pins can
#      leave its hook untrusted, which codex silently skips
#
# The sync comes before the upgrade because it replaces
# ~/.config/mise/config.toml with the repo's pins; the upgrade then bumps
# anything newer on top, rather than the sync undoing the bumps. Steps 2-5 run
# from the fresh clone, so they use the current scripts, not the image's. A
# failed or cancelled step only warns, so the wrapped command still runs
# offline.
#
# Overridable via environment:
#   DOTFILES_REPO    git URL to clone   (default: https://github.com/rahulmutt/dev.git)
#   DOTFILES_BRANCH  branch to clone    (default: main)
set -euo pipefail

# Like post-create.sh, this may run without the image's ENV PATH
# (base/Dockerfile), e.g. under DevPod's Kubernetes provider.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

REPO_URL="${DOTFILES_REPO:-https://github.com/rahulmutt/dev.git}"
REPO_BRANCH="${DOTFILES_BRANCH:-main}"

# step <description> <command...>: run it, warning instead of failing.
step() {
  local what="$1" status=0
  shift
  "$@" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "env-update: ${what} failed (exit ${status}), continuing" >&2
  fi
  return "$status"
}

# tool_step <tool> <description> <command...>: step, skipped if <tool> is
# missing.
tool_step() {
  local tool="$1"
  shift
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "env-update: ${tool} not installed, skipping its plugins"
    return 0
  fi
  step "$@"
}

clone="$(mktemp -d)"
trap 'rm -rf "$clone"' EXIT

step "mise self-update" mise self-update || true

repo=""
if step "cloning ${REPO_URL}" git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$clone/dev"; then
  repo="$clone/dev"
  step "dotfiles sync" bash "$repo/scripts/sync-dotfiles.sh" || true
fi

step "toolchain upgrade" mise upgrade --interactive --bump || true

if [ -n "$repo" ]; then
  tool_step claude "claude plugin update" bash "$repo/scripts/install-claude-plugins.sh" --update || true
  tool_step codex "codex plugin update" bash "$repo/scripts/install-codex-plugins.sh" --update || true
  tool_step pi "pi package update" bash "$repo/scripts/install-pi-packages.sh" --update || true
  if command -v codex >/dev/null 2>&1 &&
    ! step "codex hook trust check" bash "$repo/scripts/codex-hook-hashes.sh" --check; then
    echo "env-update: to re-trust, paste the output of scripts/codex-hook-hashes.sh (from a checkout) into ~/.codex/config.toml" >&2
  fi
fi

# exec skips the EXIT trap, so clean up first.
rm -rf "$clone"
trap - EXIT

if [ "$#" -gt 0 ]; then
  exec "$@"
fi
