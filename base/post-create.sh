#!/usr/bin/env bash
set -euo pipefail

if [ -f mise.toml ]; then 
  mise trust --yes mise.toml || true
  mise install 
fi

if [ ! -d ~/.config/nvim ]; then 
  git clone https://github.com/LazyVim/starter ~/.config/nvim
fi

eval "$(mise activate bash)" 

pi install npm:@rahulmutt/pi-ralph || true
pi install npm:pi-web-access || true
