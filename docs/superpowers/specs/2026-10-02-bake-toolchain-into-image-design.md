# Bake the toolchain into the image

## Problem

The image ships almost nothing installed. `base/post-create.sh` runs on every
container creation and does the real work: `mise install` of the ~26 pinned
tools in `.config/mise/config.toml`, the tmux and nvim plugin installs, and —
when `INSTALL_NIX` / `INSTALL_DEVENV` are set — a single-user Nix install plus
devenv. A fresh container is therefore minutes away from usable, and every
container repeats the same downloads.

Two further issues:

- The mise binary is installed by root to `/usr/local/bin/mise`
  (`base/Dockerfile`), while everything it manages lives under the `dev`
  user's home. It should be a user install.
- Moving `mise install` into the build naively puts the whole toolchain in one
  layer, so the daily `mise-bump` PR — which typically moves one or two pins —
  would re-download every tool on every bump.

## Goals

- Everything `post-create.sh` installs today is installed at `docker build`
  time. A new container is ready on start.
- Nix and devenv are always installed (no opt-in).
- mise is installed by, and owned by, the `dev` user.
- Bumping one pin downloads only that tool, locally and in CI.

## Non-goals

- Per-tool build stages / per-tool layers. Considered and declined in favour
  of a single toolchain layer backed by BuildKit cache mounts: a bump rebuilds
  and re-uploads the toolchain layer, but re-extracts from local archives
  rather than re-downloading.
- Image variants. One image, one tag scheme, as today.
- Changing `mise-bump.yaml` or `scripts/mise-bump.sh`.

## Design

### Dockerfile layout (`base/Dockerfile`)

Ordered from least to most frequently changing, so mise bumps never invalidate
the Nix layer:

1. **apt + user creation.** Unchanged. `/nix` is still created and chowned to
   `dev`.
2. **Nix + devenv, as `dev`.** Single-user install
   (`sh <(curl -L https://nixos.org/nix/install) --no-daemon --no-channel-add`),
   using the existing `/etc/nix/nix.conf` (copied before this step). devenv is
   installed with `nix profile install` from a nixpkgs flake reference pinned
   to a specific revision (not the floating `nixpkgs#devenv`), so rebuilds are
   reproducible. `.bashrc` sources `~/.nix-profile/etc/profile.d/nix.sh`. The
   `PATH` env already includes `~/.nix-profile/bin`.
3. **mise binary, as `dev`.** `curl -fsSL https://mise.run | sh` with
   `MISE_INSTALL_PATH=/home/dev/.local/bin/mise` and a pinned `MISE_VERSION`
   build arg. `~/.local/bin` is added to `PATH`. The `.bashrc` activation line
   becomes `eval "$(~/.local/bin/mise activate bash)"`. The
   `/usr/local/bin/mise` install is removed.
4. **Toolchain.** `COPY --chown=dev .config/mise/config.toml` alone (before
   the rest of `.config/`, so dotfile edits don't invalidate it), then:

   The Dockerfile gains a `# syntax=docker/dockerfile:1` header, needed for
   secret mounts with `env=`.

   ```dockerfile
   ARG TARGETARCH
   RUN --mount=type=cache,id=mise-downloads-${TARGETARCH},target=/home/dev/.local/share/mise/downloads,uid=1000,gid=1000 \
       --mount=type=cache,id=mise-cache-${TARGETARCH},target=/home/dev/.cache/mise,uid=1000,gid=1000 \
       --mount=type=cache,id=npm-${TARGETARCH},target=/home/dev/.npm,uid=1000,gid=1000 \
       --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
       MISE_ALWAYS_KEEP_DOWNLOAD=1 mise install
   ```

   Tools install into the real `~/.local/share/mise/installs`, so nothing is
   relocated after install. The cache mounts hold only downloaded archives,
   mise's metadata cache and the npm cache; they are not part of the image.
   On a bump the layer re-runs, re-extracting every tool from the cached
   archives and downloading only the changed one. `TARGETARCH` in each id
   keeps amd64 and arm64 archives apart.

   The optional `github_token` secret authenticates GitHub API calls made by
   the github/aqua backends, avoiding the 60 req/hour unauthenticated limit.
   Local builds work without it.
5. **Editor/terminal setup.** tpm and LazyVim clones (as today), the remaining
   dotfile `COPY`s, then
   `~/.tmux/plugins/tpm/bin/install_plugins` and
   `nvim --headless "+Lazy! sync" +qa`, moved from `post-create.sh`.

### `base/post-create.sh`

Kept at `/usr/local/bin/post-create.sh` so existing `devcontainer.json` files
calling it keep working. It is reduced to the work that can only happen once
the workspace exists:

- `mise trust --yes` the workspace's `mise.toml` and
  `.config/mise/config.toml` if present (unchanged logic).
- `mise install`. The home toolchain is already present, so this only
  installs workspace-specific tools.
- If `INSTALL_NIX` or `INSTALL_DEVENV` is set, print one line saying Nix and
  devenv are now always installed and the variable can be removed. Not an
  error.

The Nix, devenv, tmux-plugin and nvim-plugin sections are removed.

### CI

**`.github/workflows/devpod.yaml`**

- Matrix becomes `arch: [amd64, arm64]`; the `variant` axis is removed.
- Before the build, `actions/cache` restores the cache-mount contents:
  key `buildkit-mounts-${arch}-${hashFiles('.config/mise/config.toml')}`,
  restore-keys `buildkit-mounts-${arch}-`, so a bump restores the previous
  run's archives.
- `reproducible-containers/buildkit-cache-dance` (pinned by SHA) injects that
  directory into the three cache mounts before the build and extracts them
  after, with a `cache-map` matching the ids and targets above.
- The build step passes `secrets: github_token=${{ secrets.GITHUB_TOKEN }}`.
- The validate step drops the variant argument.

**`.github/workflows/base.yaml`**: no cache-dance. The multi-arch push reads
the per-arch layer caches the validate legs just wrote, so the toolchain layer
is a cache hit and the mounts are never consulted. The only change is passing
the same `github_token` secret, so a layer-cache miss (e.g. an evicted entry)
still builds.

### Validation (`scripts/validate-devpod.sh`)

- The `variant` argument and the `remoteEnv` injection are removed.
- `nix --version` and `devenv version` are always asserted.
- New assertions: `command -v mise` is `/home/dev/.local/bin/mise`, and that
  file is owned by `dev`.
- Existing assertions (user, sudo, workspace marker, tmux/nvim plugins,
  `mise ls --missing`, every tool executes) are kept.

Root `mise.toml`: the `validate-devpod-devenv` task is removed.

### Docs (`README.md`)

- "Optional components" becomes a note that Nix and devenv are always
  included; the `INSTALL_*` table and example are removed.
- The `post-create.sh` paragraph and "Toolchain versions" section describe
  the build-time install and the slimmed script.
- The Development section drops the devenv variant and describes the
  arch-only matrix.

## Testing

- `mise run check` (shellcheck + existing tests) passes.
- `mise run validate-devpod` passes locally.
- Cache behaviour, verified once by hand: build; bump one pin in
  `.config/mise/config.toml`; rebuild with `--progress=plain`; confirm from
  the log that only the bumped tool is downloaded. If a backend (core, aqua,
  github, npm) turns out not to reuse the cached download, stop and revisit
  the design rather than work around it silently.
- CI: the devpod workflow passes on both architectures.

## Risks

- **Not every backend may honour `always_keep_download`.** Covered by the
  manual cache test above.
- **Image size** grows by the Nix store and devenv closure (estimated a few
  hundred MB) plus the full toolchain. Accepted.
- **Cache-dance fragility.** If the cache-mount restore fails, the build still
  succeeds — it just downloads everything, as a cold build would.
