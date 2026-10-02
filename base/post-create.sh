#!/usr/bin/env bash
#
# post-create.sh — runs on container creation (the devcontainer
# postCreateCommand), from the workspace folder.
#
# The home toolchain, Nix, devenv and the tmux/nvim plugins are all baked into
# the image at build time (base/Dockerfile). This only does what needs the
# workspace to exist: its own mise config.
set -euo pipefail

# --- legacy opt-ins ---
for var in INSTALL_NIX INSTALL_DEVENV; do
  if [ -n "${!var:-}" ]; then
    echo "post-create.sh: ${var} is no longer needed -- Nix and devenv are always installed. You can remove it." >&2
  fi
done

# --- trust project mise config if present ---
if [ -f mise.toml ]; then
  mise trust --yes mise.toml || true
fi

if [ -f .config/mise/config.toml ]; then
  mise trust --yes .config/mise/config.toml || true
fi

# --- install workspace mise tools (the home toolchain is already present) ---
mise install
