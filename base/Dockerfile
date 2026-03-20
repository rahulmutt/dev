FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV MISE_INSTALL_PATH=/usr/local/bin/mise

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
    tmux \
    xz-utils \
    zip \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://mise.run | sh \
 && mkdir -p /root/.cache /root/.local /workspace \
 && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> /root/.bashrc \
 && echo 'alias vim=nvim' >> /root/.bashrc \
 && curl -o /tmp/xterm-kitty.terminfo https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo \
 && tic -x /tmp/xterm-kitty.terminfo \
 && rm /tmp/xterm-kitty.terminfo

COPY ./tmux-dev /usr/local/bin/tmux-dev
COPY ./post-create.sh /usr/local/bin/post-create.sh
RUN chmod +x /usr/local/bin/tmux-dev \
 && chmod +x /usr/local/bin/post-create.sh 

WORKDIR /workspace

CMD ["/bin/bash"]
