# dev

A batteries-included [Dev Container](https://containers.dev/) image for everyday
development, published to `ghcr.io/rahulmutt/dev`.

It ships a Debian (trixie) base with a curated toolchain, AI coding agents, and
sensible dotfiles already in place, so a fresh container is ready to work in.

## Usage

Point your Dev Container at the published image. A minimal
`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "dev",
  "image": "ghcr.io/rahulmutt/dev:sha-c6a8c12",
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "post-create.sh"
}
```

Works with VS Code Dev Containers, [DevPod](https://devpod.sh/), GitHub
Codespaces, or any other [`devcontainer`](https://containers.dev/) runtime.

### Image tags

Every commit on `main` whose CI build passes (the green check mark) is published
to GHCR and can be pulled by any OCI-compatible container runtime — Docker,
Podman, containerd/nerdctl, etc. Images are multi-arch (`linux/amd64` and
`linux/arm64`). Two tags are produced per build:

- `ghcr.io/rahulmutt/dev:latest` — the most recent successful `main` build.
- `ghcr.io/rahulmutt/dev:sha-<short-sha>` — a specific commit (e.g.
  `sha-c6a8c12`), pinned and immutable.

```sh
docker pull ghcr.io/rahulmutt/dev:latest
podman pull ghcr.io/rahulmutt/dev:sha-c6a8c12
```

Pin to a `sha-` tag for reproducible environments; use `latest` to track the tip
of `main`.

The `post-create.sh` step (baked into the image) runs on container creation to
finish setup: installing the mise-managed toolchain, tmux/nvim plugins, and any
optional components you enabled via environment variables (see below).

## What's inside

- **Base:** Debian trixie, non-root `dev` user with passwordless `sudo`, UTF-8
  locale, `nvim` as `$EDITOR`, Chromium for headless browser use.
- **Toolchain** (managed by [mise](https://mise.jdx.dev/), see
  `.config/mise/config.toml`): ripgrep, fd, fzf, jq, bat, glow, btop, lazygit,
  gh, tmux, tree-sitter, neovim, node, bun, python, dprint, ttyd.
- **AI coding agents:** [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent),
  [claude](https://www.npmjs.com/package/@anthropic-ai/claude-code),
  [codex](https://www.npmjs.com/package/@openai/codex), and opencode — plus
  `codeburn`, `skills`, `vsync`, and `nono`.
- **Dotfiles:** preconfigured `.claude`, `.codex`, `.config`, `.pi`, and
  `.tmux.conf`.

## Configuration

### Optional components (environment variables)

These are read by `post-create.sh` at container-creation time. Set them through
your Dev Container's `remoteEnv`/`containerEnv` (or the host environment) to opt
into extra tooling. All default to off.

| Variable         | Effect                                                              |
| ---------------- | ------------------------------------------------------------------- |
| `INSTALL_NIX`    | Install Nix (single-user) and wire it into `.bashrc`.               |
| `INSTALL_DEVENV` | Install [devenv](https://devenv.sh/) (implies `INSTALL_NIX=true`).  |
| `INSTALL_NGROK`  | Install the [ngrok](https://ngrok.com/) agent.                      |

Example:

```jsonc
{
  "image": "ghcr.io/rahulmutt/dev:sha-c6a8c12",
  "postCreateCommand": "post-create.sh",
  "remoteEnv": {
    "INSTALL_DEVENV": "true",
    "INSTALL_NGROK": "true"
  }
}
```

### Toolchain versions

Pin or change tool versions by editing `.config/mise/config.toml`. The
`post-create.sh` step runs `mise install` to apply it.

### pi plugins

pi's plugins are declared in `.pi/agent/settings.json`:

```json
{
  "packages": [
    "npm:@rahulmutt/pi-ralph",
    "npm:pi-web-access",
    "npm:pi-subagents"
  ]
}
```

Add or remove entries there — pi installs any missing ones automatically on its
next startup. No manual `pi install` step is needed.

## ngrok

Traffic policy files for the ngrok agent live in `ngrok/`:

- `traffic-policy-google.yaml`
- `traffic-policy-token-whitelist.yaml`

Use one with:

```sh
ngrok http <port> --traffic-policy-file=ngrok/<policy>.yaml
```
