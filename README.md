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

## Syncing the dotfiles to your own machine

You don't need the container to use these dotfiles. The repo ships a sync tool
that copies the tracked dotfiles (`.claude`, `.codex`, `.config`, `.pi`,
`.tmux.conf`) into your home directory.

It is safe by design: for each file it compares the SHA-256 of the repo copy
against the one already on your system, skips anything identical, and — before
replacing a file that differs — backs the existing one up next to the original
as `<file>.bak.<timestamp>`. Because it only ever syncs git-tracked files,
anything ignored by `.gitignore` (credentials such as `.pi/agent/auth.json`,
installed packages) is never touched.

### One-line install

Clone into a temp directory, sync, and clean up — all in one go:

```sh
curl -fsSL https://raw.githubusercontent.com/rahulmutt/dev/main/scripts/install.sh | sh
```

Preview first without changing anything, or skip the confirmation prompt, by
passing flags through after `-s --`:

Show what would change, modify nothing:

```sh
curl -fsSL https://raw.githubusercontent.com/rahulmutt/dev/main/scripts/install.sh | sh -s -- --dry-run
```

Apply without the interactive prompt:

```sh
curl -fsSL https://raw.githubusercontent.com/rahulmutt/dev/main/scripts/install.sh | sh -s -- --yes
```

### From a local checkout

If you already have the repo cloned, run the sync script directly:

```sh
scripts/sync-dotfiles.sh            # preview the diffs, then confirm
scripts/sync-dotfiles.sh --dry-run  # preview only, change nothing
scripts/sync-dotfiles.sh --quiet    # just list the files, no diffs
scripts/sync-dotfiles.sh --verbose  # also list the unchanged files by name
scripts/sync-dotfiles.sh --yes      # apply without the prompt
scripts/sync-dotfiles.sh --home DIR # sync into a different target directory
```

By default the sync prints a unified diff of every file it will create or
update, so you can review the exact changes before confirming. Pass `--quiet`
(`-q`) to suppress the diffs and just list the affected files, or `--verbose`
(`-v`) to additionally list the unchanged files by name. Combine the default
output with `--dry-run` to inspect the diffs without touching anything:

```sh
scripts/sync-dotfiles.sh --dry-run
```

The one-line installer forwards these flags too, e.g.:

```sh
curl -fsSL https://raw.githubusercontent.com/rahulmutt/dev/main/scripts/install.sh | sh -s -- --dry-run
```

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

## Development

The repo's own dev tooling is declared in the root `mise.toml` (separate from
the home toolchain in `.config/mise/config.toml`). It pins `shellcheck` and
defines a few tasks:

```sh
mise run lint   # shellcheck every shell script
mise run test   # run the dotfiles-sync integration tests
mise run check  # lint + test

mise run validate-devpod  # build the image and check `devpod up` works on it
```

The integration tests in `scripts/tests/` exercise `sync-dotfiles.sh` against a
throwaway `$HOME`, covering the safe-backup behaviour (adjacent timestamped
backups, skipping identical files, never syncing git-ignored secrets).

`validate-devpod` (needs docker and [devpod](https://devpod.sh/); not part of
`check`, since it builds the image) hands the image to
`scripts/validate-devpod.sh`, which brings up a throwaway DevPod workspace on a
synthetic `devcontainer.json` — running the real `post-create.sh` — then asserts
the container is usable: the `dev` user with passwordless sudo, the workspace
source at `/workspace`, tmux and nvim plugins installed, and every tool in
`.config/mise/config.toml` actually executing (not merely resolving to a mise
shim).

The script takes an optional variant:

```sh
scripts/validate-devpod.sh dev:ci           # the image as shipped
scripts/validate-devpod.sh dev:ci devenv    # also INSTALL_DEVENV=true
```

The `devenv` variant sets `INSTALL_DEVENV` through `remoteEnv`, the same way the
[Optional components](#optional-components-environment-variables) table above
tells you to, so `post-create.sh` installs Nix and devenv; it then additionally
asserts `nix` and `devenv` run. This is the only coverage the optional
components get.

CI runs the same script as a reusable workflow (`.github/workflows/devpod.yaml`),
as a `[default, devenv]` matrix: on pull requests, and on `main` as a gate in
front of the GHCR push, so an image that cannot `devpod up` is never published.
It validates `linux/amd64` only — the runner's architecture — so the
`linux/arm64` half of the published manifest is built but not exercised.

## ngrok

Traffic policy files for the ngrok agent live in `ngrok/`:

- `traffic-policy-google.yaml`
- `traffic-policy-token-whitelist.yaml`

Use one with:

```sh
ngrok http <port> --traffic-policy-file=ngrok/<policy>.yaml
```
