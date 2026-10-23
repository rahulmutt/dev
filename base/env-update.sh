#!/usr/bin/env bash
#
# env-update — update mise, the dotfiles and the toolchain, then run a command.
#
#   env-update                  # update, then exit
#   env-update claude --resume  # update, then exec `claude --resume`
#
# Runs `mise self-update`, then syncs the dotfiles from the latest repo
# (install.sh, which shows each change and asks before applying it), then
# `mise upgrade --interactive --bump`. The sync comes before the upgrade
# because it replaces ~/.config/mise/config.toml with the repo's pins; the
# upgrade then bumps anything newer on top, rather than the sync undoing the
# bumps. A failed or cancelled step only warns, so the wrapped command still
# runs offline.
#
# Overridable via environment:
#   DOTFILES_INSTALL  dotfiles installer to run (default: the one in the image)
set -euo pipefail

# Like post-create.sh, this may run without the image's ENV PATH
# (base/Dockerfile), e.g. under DevPod's Kubernetes provider.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

DOTFILES_INSTALL="${DOTFILES_INSTALL:-/usr/local/share/dev/install.sh}"

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

step "mise self-update" mise self-update || true
step "dotfiles sync" sh "$DOTFILES_INSTALL" || true
step "toolchain upgrade" mise upgrade --interactive --bump || true

if [ "$#" -gt 0 ]; then
  exec "$@"
fi
