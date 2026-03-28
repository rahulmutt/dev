FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# mise
ENV MISE_INSTALL_PATH=/usr/local/bin/mise
ENV PATH="/root/.local/share/mise/shims:/root/.local/share/mise/bin:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
ENV MISE_DATA_DIR="/root/.local/share/mise"
ENV MISE_CACHE_DIR="/root/.cache/mise"
ENV EDITOR="nvim"
ENV SHELL="/bin/bash"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    openssh-client \
    procps \
    build-essential \
    pkg-config \
    libssl-dev \
    unzip \
    gnupg \
    xz-utils \
    zip \
 && rm -rf /var/lib/apt/lists/*

# --- install mise ---
RUN curl -fsSL https://mise.run | sh

# --- shell setup ---
RUN mkdir -p /root/.cache /root/.local /workspace \
 && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> /root/.bashrc \
 && echo 'alias vim=nvim' >> /root/.bashrc

# --- dev tooling ---
RUN git clone https://github.com/tmux-plugins/tpm /root/.tmux/plugins/tpm \
 && git clone https://github.com/LazyVim/starter /root/.config/nvim \
 && rm -rf /root/.config/nvim/.git

COPY ./.config/nix/nix.conf /etc/nix/nix.conf
COPY ./.config/nvim/lua/plugins/tmux.lua /root/.config/nvim/lua/plugins/tmux.lua
COPY ./.config/mise/config.toml /root/.config/mise/config.toml
COPY ./base/tmux-dev /usr/local/bin/tmux-dev
COPY ./base/post-create.sh /usr/local/bin/post-create.sh
COPY ./.tmux.conf /root/.tmux.conf

RUN chmod +x /usr/local/bin/tmux-dev \
 && chmod +x /usr/local/bin/post-create.sh

WORKDIR /workspace

CMD ["/bin/bash"]
