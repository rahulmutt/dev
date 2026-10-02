# syntax=docker/dockerfile:1
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- user config ----
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000

# ---- base env ----
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV EDITOR="nvim"
ENV SHELL="/bin/bash"
ENV DEBIAN_CODENAME="trixie"
ENV PUPPETEER_SKIP_DOWNLOAD=1
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_BIN=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# ---- install system deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
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
    chromium \
    fonts-liberation \
    fonts-noto-color-emoji \
    iproute2 \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# ---- create non-root user with passwordless sudo ----
RUN groupadd --gid ${GID} ${USERNAME} \
 && useradd --uid ${UID} --gid ${GID} -m -s /bin/bash ${USERNAME} \
 && usermod -aG sudo ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 && mkdir -p /workspace /nix /etc/nix \
 && chown -R ${USERNAME}:${USERNAME} /workspace /nix /home/${USERNAME}

# ---- user-scoped paths ----
# Set here rather than in .bashrc so non-interactive shells (devpod ssh
# --command, IDE tasks) find mise, the toolchain, nix and devenv too.
ENV USER=${USERNAME}
ENV MISE_INSTALL_PATH="/home/${USERNAME}/.local/bin/mise"
ENV MISE_DATA_DIR="/home/${USERNAME}/.local/share/mise"
ENV MISE_CACHE_DIR="/home/${USERNAME}/.cache/mise"
ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

COPY ./.config/nix/nix.conf /etc/nix/nix.conf

# ---- switch to user for user-level setup ----
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# ---- shell setup ----
# The cache-mount targets below are created here, as the user, so BuildKit
# doesn't create their parents as root when it mounts them.
RUN mkdir -p \
      "${HOME}/.local/bin" \
      "${HOME}/.local/share/mise/downloads" \
      "${HOME}/.cache/mise" \
      "${HOME}/.npm" \
      "${HOME}/.config/mise" \
 && echo 'alias vim=nvim' >> "${HOME}/.bashrc"

# ---- nix (single-user) + devenv ----
# Ahead of mise so that toolchain bumps never invalidate this layer.
ARG NIX_VERSION=2.35.2
# nixos-26.05 as of 2026-10-02 (devenv 2.1.2).
ARG NIXPKGS_REV=4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1
# The single quotes are intentional: the literal line goes into .bashrc and is
# expanded when bash starts.
RUN curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" | sh -s -- --no-daemon --no-channel-add \
 && . "${HOME}/.nix-profile/etc/profile.d/nix.sh" \
 && nix profile install "https://github.com/NixOS/nixpkgs/archive/${NIXPKGS_REV}.tar.gz#devenv" \
 && nix-collect-garbage -d \
 && nix-store --optimise \
 && echo '. "$HOME/.nix-profile/etc/profile.d/nix.sh"' >> "${HOME}/.bashrc"

# ---- install mise (as the user) ----
ARG MISE_VERSION=v2026.10.0
RUN curl -fsSL https://mise.run | MISE_VERSION="${MISE_VERSION}" sh \
 && echo 'eval "$(~/.local/bin/mise activate bash)"' >> "${HOME}/.bashrc"

# ---- mise toolchain ----
# config.toml is copied on its own so edits to other dotfiles don't invalidate
# this layer. The cache mounts keep downloaded archives (not installs) across
# builds, so a bump re-extracts every tool locally but downloads only the one
# that changed. The build log lists the files written during `mise install`
# (an mtime stamp, so a re-download over an existing path is caught too): the
# downloads, then the npm: tools' package store. CI persists the mounts across
# runners with buildkit-cache-dance (.github/workflows/devpod.yaml); the ids and
# targets must match there.
#
# chown: mounts injected by cache-dance can arrive root-owned.
# Prune: drop downloads for versions no longer installed, so the cache doesn't
# grow with every bump.
COPY --chown=${USERNAME}:${USERNAME} ./.config/mise/config.toml /home/${USERNAME}/.config/mise/config.toml
ARG TARGETARCH
RUN --mount=type=cache,id=mise-downloads-${TARGETARCH},target=/home/${USERNAME}/.local/share/mise/downloads,uid=${UID},gid=${GID} \
    --mount=type=cache,id=mise-cache-${TARGETARCH},target=/home/${USERNAME}/.cache/mise,uid=${UID},gid=${GID} \
    --mount=type=cache,id=npm-${TARGETARCH},target=/home/${USERNAME}/.npm,uid=${UID},gid=${GID} \
    --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    sudo chown -R "${UID}:${GID}" "${MISE_DATA_DIR}/downloads" "${MISE_CACHE_DIR}" "${HOME}/.npm" \
 && touch /tmp/mise-stamp \
 && MISE_ALWAYS_KEEP_DOWNLOAD=1 mise install \
 && echo "==> mise downloaded (not served from cache):" \
 && ( cd "${MISE_DATA_DIR}/downloads" && find . -type f -newer /tmp/mise-stamp | sed 's|^\./||' | sort ) \
 && echo "==> mise npm store written (not served from cache):" \
 && if [ -d "${MISE_CACHE_DIR}/npm" ]; then \
      ( cd "${MISE_CACHE_DIR}" && find npm -type f -newer /tmp/mise-stamp | sort ); \
    fi \
 && rm /tmp/mise-stamp \
 && for d in "${MISE_DATA_DIR}"/downloads/*/*/; do \
      rel="${d#"${MISE_DATA_DIR}"/downloads/}"; \
      [ -d "${MISE_DATA_DIR}/installs/${rel}" ] || rm -rf "$d"; \
    done

# ---- dev tooling ----
RUN git clone https://github.com/tmux-plugins/tpm "${HOME}/.tmux/plugins/tpm" \
 && git clone https://github.com/LazyVim/starter "${HOME}/.config/nvim" \
 && rm -rf "${HOME}/.config/nvim/.git"

# ---- copy user configs ----
COPY --chown=${USERNAME}:${USERNAME} ./.claude/ /home/${USERNAME}/.claude/
COPY --chown=${USERNAME}:${USERNAME} ./.codex/ /home/${USERNAME}/.codex/
COPY --chown=${USERNAME}:${USERNAME} ./.config/ /home/${USERNAME}/.config/
COPY --chown=${USERNAME}:${USERNAME} ./.pi/ /home/${USERNAME}/.pi/
COPY --chown=${USERNAME}:${USERNAME} ./.tmux.conf /home/${USERNAME}/.tmux.conf

# ---- tmux and nvim plugins ----
# Best effort, as they were in post-create.sh.
RUN ( "${HOME}/.tmux/plugins/tpm/bin/install_plugins" || true ) \
 && ( nvim --headless "+Lazy! sync" +qa || true )

# ---- container-creation hook ----
# Last, so editing it rebuilds nothing else.
COPY --chmod=0755 ./base/post-create.sh /usr/local/bin/post-create.sh

WORKDIR /workspace

CMD ["/bin/bash"]
