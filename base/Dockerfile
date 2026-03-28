FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- user config ----
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000

# ---- base env ----
ENV EDITOR="nvim"
ENV SHELL="/bin/bash"
ENV DEBIAN_CODENAME="trixie"

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
    sudo \
 && rm -rf /var/lib/apt/lists/*

# ---- create non-root user with passwordless sudo ----
RUN groupadd --gid ${GID} ${USERNAME} \
 && useradd --uid ${UID} --gid ${GID} -m -s /bin/bash ${USERNAME} \
 && usermod -aG sudo ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 && mkdir -p /workspace /nix /etc/nix \
 && chown -R ${USERNAME}:${USERNAME} /workspace /nix /home/${USERNAME}

# ---- mise paths (user-scoped) ----
ENV MISE_INSTALL_PATH=/usr/local/bin/mise
ENV MISE_DATA_DIR="/home/${USERNAME}/.local/share/mise"
ENV MISE_CACHE_DIR="/home/${USERNAME}/.cache/mise"
ENV PATH="/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.local/share/mise/bin:/home/${USERNAME}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ---- install mise ----
RUN curl -fsSL https://mise.run | sh

# ---- copy root-owned system files ----
COPY ./.config/nix/nix.conf /etc/nix/nix.conf
COPY ./base/tmux-dev /usr/local/bin/tmux-dev
COPY ./base/post-create.sh /usr/local/bin/post-create.sh

RUN chmod +x /usr/local/bin/tmux-dev /usr/local/bin/post-create.sh

# ---- switch to user for user-level setup ----
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# ---- shell setup ----
RUN mkdir -p \
      "${HOME}/.cache" \
      "${HOME}/.local" \
      "${HOME}/.config/mise" \
      /workspace \
 && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> "${HOME}/.bashrc" \
 && echo 'alias vim=nvim' >> "${HOME}/.bashrc"

# ---- dev tooling ----
RUN git clone https://github.com/tmux-plugins/tpm "${HOME}/.tmux/plugins/tpm" \
 && git clone https://github.com/LazyVim/starter "${HOME}/.config/nvim" \
 && rm -rf "${HOME}/.config/nvim/.git"

# ---- copy user configs ----
COPY --chown=${USERNAME}:${USERNAME} ./.config/nvim/lua/plugins/tmux.lua /home/${USERNAME}/.config/nvim/lua/plugins/tmux.lua
COPY --chown=${USERNAME}:${USERNAME} ./.config/mise/config.toml /home/${USERNAME}/.config/mise/config.toml
COPY --chown=${USERNAME}:${USERNAME} ./.tmux.conf /home/${USERNAME}/.tmux.conf

WORKDIR /workspace

CMD ["/bin/bash"]
