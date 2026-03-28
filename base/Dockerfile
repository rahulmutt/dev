FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- user config ----
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000

# ---- base env ----
ENV EDITOR="nvim"
ENV SHELL="/bin/bash"

# ---- install system deps ----
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

# ---- create non-root user ----
RUN groupadd --gid ${GID} ${USERNAME} \
 && useradd --uid ${UID} --gid ${GID} -m -s /bin/bash ${USERNAME} \
 && mkdir -p /workspace \
 && chown -R ${USERNAME}:${USERNAME} /workspace

# ---- mise paths (user-scoped) ----
ENV MISE_INSTALL_PATH=/usr/local/bin/mise
ENV MISE_DATA_DIR="/home/${USERNAME}/.local/share/mise"
ENV MISE_CACHE_DIR="/home/${USERNAME}/.cache/mise"

ENV PATH="/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.local/share/mise/bin:/home/${USERNAME}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ---- install mise ----
RUN curl -fsSL https://mise.run | sh

# ---- switch to user for user-level setup ----
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# ---- shell setup ----
RUN mkdir -p ~/.cache ~/.local /workspace \
 && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> ~/.bashrc \
 && echo 'alias vim=nvim' >> ~/.bashrc

# ---- dev tooling ----
RUN git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm \
 && git clone https://github.com/LazyVim/starter ~/.config/nvim \
 && rm -rf ~/.config/nvim/.git

# ---- copy configs ----
COPY --chown=${USERNAME}:${USERNAME} ./.config/mise/config.toml /home/${USERNAME}/.config/mise/config.toml
COPY --chown=${USERNAME}:${USERNAME} ./.config/nvim/lua/plugins/tmux.lua /home/${USERNAME}/.config/nvim/lua/plugins/tmux.lua
COPY --chown=${USERNAME}:${USERNAME} ./.tmux.conf /home/${USERNAME}/.tmux.conf

# ---- root-level configs (still need root) ----
USER root
COPY ./.config/nix/nix.conf /etc/nix/nix.conf
COPY ./base/tmux-dev /usr/local/bin/tmux-dev
COPY ./base/post-create.sh /usr/local/bin/post-create.sh

RUN chmod +x /usr/local/bin/tmux-dev \
 && chmod +x /usr/local/bin/post-create.sh

# ---- ensure ownership ----
RUN chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# ---- switch back to user ----
USER ${USERNAME}
WORKDIR /workspace

CMD ["/bin/bash"]
