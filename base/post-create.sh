#!/usr/bin/env bash
set -euo pipefail

# --- trust project mise config if present ---
if [ -f mise.toml ]; then 
  mise trust --yes mise.toml || true
fi

# --- install mise-managed tools ---
mise install

# --- install tmux plugins ---
if [ -x "${HOME}/.tmux/plugins/tpm/bin/install_plugins" ]; then
  "${HOME}/.tmux/plugins/tpm/bin/install_plugins" || true
fi

# --- install nvim plugins ---
if command -v nvim >/dev/null 2>&1; then
  nvim --headless "+Lazy! sync" +qa || true
fi

# --- devenv implies nix ---
if [ "${INSTALL_DEVENV:-}" = "true" ]; then
  INSTALL_NIX="${INSTALL_NIX:-true}"
fi

# --- install ngrok (system-level) ---
if [ "${INSTALL_NGROK:-}" = "true" ]; then
  sudo mkdir -p /etc/apt/keyrings

  curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/ngrok.gpg

  sudo chmod 0644 /etc/apt/keyrings/ngrok.gpg

  echo "deb [signed-by=/etc/apt/keyrings/ngrok.gpg] https://ngrok-agent.s3.amazonaws.com bookworm main" \
    | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends ngrok
  sudo rm -rf /var/lib/apt/lists/*
fi

# --- install nix (single-user) ---
if [ "${INSTALL_NIX:-}" = "true" ]; then
  if [ ! -e "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]; then
    # ensure /nix exists + owned correctly
    if [ ! -d /nix ]; then
      sudo mkdir -p /nix
    fi

    sudo chown "$(id -u):$(id -g)" /nix
    sudo chmod 0755 /nix

    mkdir -p "${HOME}/.config/nix"

    curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
  fi

  # shellcheck disable=SC1090
  . "${HOME}/.nix-profile/etc/profile.d/nix.sh"

  if ! grep -Fq '. "$HOME/.nix-profile/etc/profile.d/nix.sh"' "${HOME}/.bashrc" 2>/dev/null; then
    echo '. "$HOME/.nix-profile/etc/profile.d/nix.sh"' >> "${HOME}/.bashrc"
  fi
fi

# --- install devenv ---
if [ "${INSTALL_DEVENV:-}" = "true" ]; then
  # shellcheck disable=SC1090
  . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
  nix profile install nixpkgs#devenv
fi

# --- pi tooling ---
if command -v pi >/dev/null 2>&1; then
  pi install npm:@rahulmutt/pi-ralph || true
  pi install npm:pi-web-access || true
fi
