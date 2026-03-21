FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV MISE_INSTALL_PATH=/usr/local/bin/mise
ENV PATH="/root/.local/share/mise/shims:/root/.local/share/mise/bin:$PATH"
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
 && rm -rf /var/lib/apt/lists/* \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://mise.run | sh \
 && mkdir -p /root/.cache /root/.local /workspace \
 && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> /root/.bashrc \
 && echo 'alias vim=nvim' >> /root/.bashrc \
 && curl -o /tmp/xterm-kitty.terminfo https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo \
 && tic -x /tmp/xterm-kitty.terminfo \
 && rm /tmp/xterm-kitty.terminfo \
 && git clone https://github.com/tmux-plugins/tpm /root/.tmux/plugins/tpm \
 && git clone https://github.com/LazyVim/starter /root/.config/nvim \
 && rm -rf /root/.config/nvim/.git

COPY ./mise.toml /root/.config/mise/config.toml
COPY ./tmux-dev /usr/local/bin/tmux-dev
COPY ./post-create.sh /usr/local/bin/post-create.sh
COPY ./tmux.conf /root/.tmux.conf

RUN chmod +x /usr/local/bin/tmux-dev \
 && chmod +x /usr/local/bin/post-create.sh \
 && /root/.tmux/plugins/tpm/bin/install_plugins

WORKDIR /workspace

CMD ["/bin/bash"]
