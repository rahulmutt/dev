#!/usr/bin/env bash
set -euo pipefail

if [ -f mise.toml ]; then 
  mise trust --yes mise.toml || true
fi

mise install

# Install tmux plugins
~/.tmux/plugins/tpm/bin/install_plugins

# Install nvim plugins
nvim --headless "+Lazy! sync" +qa || true

# Only install if explicitly enabled
if [ "${INSTALL_NGROK:-}" = "true" ]; then
  curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
    | gpg --dearmor -o /etc/apt/keyrings/ngrok.gpg
  
  chmod 0644 /etc/apt/keyrings/ngrok.gpg
  
  echo "deb [signed-by=/etc/apt/keyrings/ngrok.gpg] https://ngrok-agent.s3.amazonaws.com bookworm main" \
    > /etc/apt/sources.list.d/ngrok.list
  
  apt-get update -y
  apt-get install -y --no-install-recommends ngrok
  
  rm -rf /var/lib/apt/lists/*
fi

if [ "${INSTALL_DEVENV:-}" = "true" ]; then
  . ~/.nix-profile/etc/profile.d/nix.sh
  nix profile install nixpkgs#devenv
fi

pi install npm:@rahulmutt/pi-ralph || true
pi install npm:pi-web-access || true
