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

The toolchain, Nix, devenv and the tmux/nvim plugins are all installed when the
image is built, so a new container is ready immediately. The `post-create.sh`
step (baked into the image) only trusts and installs the workspace's own
`mise.toml`, if it has one.

## What's inside

- **Base:** Debian trixie, non-root `dev` user with passwordless `sudo`, UTF-8
  locale, `nvim` as `$EDITOR`, Chromium for headless browser use.
- **Toolchain** (managed by a user-installed [mise](https://mise.jdx.dev/), see
  `.config/mise/config.toml`): ripgrep, fd, fzf, jq, bat, glow, btop, lazygit,
  gh, tmux, tree-sitter, neovim, node, bun, python, dprint, ttyd.
- **Nix + devenv:** single-user [Nix](https://nixos.org/) and
  [devenv](https://devenv.sh/), always installed.
- **AI coding agents:** [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent),
  [claude](https://www.npmjs.com/package/@anthropic-ai/claude-code),
  [codex](https://www.npmjs.com/package/@openai/codex), and opencode — plus
  `codeburn`, `skills`, `vsync`, and `nono`.
- **Dotfiles:** preconfigured `.claude`, `.codex`, `.config`, `.pi`, and
  `.tmux.conf`.
- **Claude plugins:** superpowers, ponytail, devkit, impeccable, claude-hud
  (the status line), chrome-devtools-mcp and a few official ones, installed at
  build time from `.claude/settings.json` by `scripts/install-claude-plugins.sh`.
  The settings also hide commit/PR attribution (including the newer
  `Claude-Session` trailer), turn off the feedback survey, Claude-drafted
  feedback, spinner tips and the self-updater (mise pins claude; update with
  `mise-update claude`). LSP plugin recommendations are off via
  `lspRecommendationDisabled` in `~/.claude.json`, which the image sets — it is
  global config, not a dotfile, so syncing the dotfiles doesn't carry it.
- **Codex plugins:** superpowers, ponytail, devkit and impeccable, installed at build time
  from `.codex/config.toml`, with their hooks pre-trusted there (no `/hooks`
  step). When a plugin changes a hook, its pinned hash goes stale and codex
  stops running it; the daily env-bump PR refreshes the `[hooks.state]` block,
  and CI's devpod check fails on a stale one. To refresh by hand, paste the
  output of `scripts/codex-hook-hashes.sh`.

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

Syncing `.claude/settings.json` and `.codex/config.toml` only declares the
Claude and Codex plugins. Fetch them with:

```sh
scripts/install-claude-plugins.sh
scripts/install-codex-plugins.sh
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

### Nix and devenv

Both are always installed. The `INSTALL_NIX` and `INSTALL_DEVENV` variables
that used to opt into them are no longer needed; if set, `post-create.sh` just
prints a reminder to remove them.

### Toolchain versions

Pin or change tool versions by editing `.config/mise/config.toml`; the image
build runs `mise install` against it. Downloaded archives are kept in BuildKit
cache mounts (persisted across CI runners); a one-pin bump re-extracts most
tools from the cache, but re-downloads the bumped tool plus those whose mise
backends ignore caching (bun, python, neovim, and github: tools like vsync
and nono). The build also accepts an optional GitHub token, since mise makes
about 26 GitHub API calls and the unauthenticated limit is 60 per hour:
`docker build --secret id=github_token,env=GITHUB_TOKEN …`.

A daily workflow (`.github/workflows/env-bump.yaml`, running
`scripts/env-bump.sh`) bumps every pin to its latest release and re-trusts
the Codex plugin hooks, then opens or refreshes a single `env-bump` PR whose
devpod checks prove the result still installs and validates.

Inside a container, `mise-update [command…]` runs `mise self-update` and
`mise upgrade --interactive --bump`, then execs the command if one is given
(e.g. `mise-update claude`). A failed or cancelled update only warns. `--bump`
rewrites the container's copy of the config, not this repo's, and
`self-update` moves mise past the image's pinned version for that container.

### pi plugins

pi's plugins are declared in `.pi/agent/settings.json`:

```json
{
  "packages": [
    "npm:pi-web-access",
    "npm:pi-subagents",
    "git:github.com/obra/superpowers",
    "git:github.com/DietrichGebert/ponytail",
    "git:github.com/rahulmutt/devkit",
    "npm:@juicesharp/rpiv-ask-user-question",
    "npm:pi-hermes-memory",
    "npm:pi-dynamic-workflows@1.0.1"
  ]
}
```

The image installs them at build time (`pi install` per entry), so a new
container starts with them ready. To change the list, edit that file and
rebuild, or just restart pi — it installs any missing entries on its next
startup. No manual `pi install` step is needed.

The same file also turns on pi's built-in `codemode` tool (`"defaultTools":
["+codemode"]`), which lets the model script several tool calls in one step.

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
synthetic `devcontainer.json` — running the real `post-create.sh` on the built
image — then asserts the container is usable: the `dev` user with passwordless
sudo, the workspace source at `/workspace`, tmux and nvim plugins installed,
Nix and devenv working, and every tool in `.config/mise/config.toml` actually
executing (not merely resolving to a mise shim).

It also runs `scripts/validate-config.sh` in the image, which checks the
baked-in Claude, Codex and pi dotfiles against the installed tools: each
tool accepts its settings (`claude doctor`, `codex doctor`), every declared
plugin and package resolves, Codex hook trust is current, and no settings
file names a versioned mise install path (use `installs/<tool>/latest/`).

CI runs the same script as a reusable workflow (`.github/workflows/devpod.yaml`),
once per architecture (`amd64`, `arm64`): on pull requests, and on
`main` as a gate in front of the GHCR push, so an image that cannot `devpod up`
is never published. Both architectures of the published manifest are booted on
native runners, so nothing is emulated. Each leg caches its build under a
per-architecture scope, which the push then reads, so it rebuilds neither. The
build's mise download cache is carried between runners with
`buildkit-cache-dance`; a one-pin bump re-downloads the bumped tool plus those
whose mise backends ignore caching (bun, python, neovim, and github: tools),
while everything else comes from the cache.

## ngrok

The image does not ship the [ngrok](https://ngrok.com/) agent, and does not
install it. These are traffic policy files for an agent you install yourself,
wherever you run it:

- `ngrok/traffic-policy-google.yaml`
- `ngrok/traffic-policy-token-whitelist.yaml`

Use one with:

```sh
ngrok http <port> --traffic-policy-file=ngrok/<policy>.yaml
```
