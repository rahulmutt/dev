# Bake the Toolchain into the Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Nix, devenv, a user-owned mise, the full mise toolchain and the tmux/nvim plugins at `docker build` time, with BuildKit cache mounts so bumping one pin downloads only that tool.

**Architecture:** `base/Dockerfile` gains (in order) a Nix+devenv layer, a user-scoped mise binary layer, and a single `mise install` layer backed by three per-arch BuildKit cache mounts (mise downloads, mise cache, npm cache). `base/post-create.sh` shrinks to workspace-only work. CI persists the cache mounts across runners with `actions/cache` + `buildkit-cache-dance`, and the devpod matrix loses its `devenv` variant.

**Tech Stack:** Dockerfile (BuildKit, `# syntax=docker/dockerfile:1`), bash, mise `v2026.10.0`, Nix `2.35.2`, nixpkgs `nixos-26.05`, GitHub Actions, DevPod.

**Spec:** `docs/superpowers/specs/2026-10-02-bake-toolchain-into-image-design.md`

## Global Constraints

- Nix and devenv are always installed; no image variants, no opt-in.
- mise binary lives at `/home/dev/.local/bin/mise`, owned by `dev`. Nothing at `/usr/local/bin/mise`.
- One `mise install` layer (no per-tool stages). Cache mounts, all suffixed `-${TARGETARCH}`: `mise-downloads` → `/home/dev/.local/share/mise/downloads`, `mise-cache` → `/home/dev/.cache/mise`, `npm` → `/home/dev/.npm`.
- `MISE_ALWAYS_KEEP_DOWNLOAD=1` on the install.
- Optional BuildKit secret `github_token`, exposed as `GITHUB_TOKEN`; local builds must work without it.
- devenv comes from a pinned nixpkgs revision: `4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1` (`nixos-26.05` on 2026-10-02, devenv 2.1.2).
- Pins: `NIX_VERSION=2.35.2`, `MISE_VERSION=v2026.10.0`, `reproducible-containers/buildkit-cache-dance@5422eac04292c961a382e0f584ea0f03ad9da723 # v3.4.0`.
- `post-create.sh` stays at `/usr/local/bin/post-create.sh`; setting `INSTALL_NIX`/`INSTALL_DEVENV` prints a notice and is not an error.
- `mise-bump.yaml` and `scripts/mise-bump.sh` are not touched.

## Environment note

This dev container has **no docker/podman**, so the image cannot be built here. Task 1 is tested offline; Tasks 2–5 are verified by `shellcheck`/review; Task 6 verifies the image in CI on a pushed branch. Pushing a branch is outward-facing — **ask the user before pushing** in Task 6.

## Review Focus

1. **Cache-mount ownership.** BuildKit (and cache-dance's injection) may create mount roots/files as root; mise running as `dev` must still be able to write. Expect: build succeeds both cold and with an injected cache. → Task 2 `sudo chown`, verified in Task 6 run 2.
2. **Non-interactive shells** (`devpod ssh --command`, IDE tasks) don't read `.bashrc`. Expect `mise`, tools, `nix`, `devenv` all resolve via image `ENV PATH`. → Task 3 smoke checks run via non-interactive `bash`.
3. **Workspace with its own `mise.toml`** at container creation. Expect it trusted and its tools installed. → Task 1 test.
4. **Existing `devcontainer.json` still setting `INSTALL_DEVENV=true`.** Expect a notice and exit 0, no Nix reinstall. → Task 1 test.
5. **Single-pin bump.** Expect only that tool to download; stale download dirs pruned so the CI cache does not grow without bound. → Task 2 download report + prune, verified in Task 6 run 2.

---

### Task 1: Slim `post-create.sh` (TDD)

**Files:**
- Create: `scripts/tests/post-create.test.sh`
- Modify: `base/post-create.sh` (full rewrite)
- Modify: `mise.toml` (`[tasks.test]`)

**Interfaces:**
- Consumes: nothing.
- Produces: `base/post-create.sh` — run from the workspace dir; calls `mise trust --yes <file>` for `mise.toml` / `.config/mise/config.toml` if present, then `mise install`; never calls `nix`, `curl`, `sudo`, `nvim`, `tmux`.

- [ ] **Step 1: Write the failing test** — `scripts/tests/post-create.test.sh`:

```bash
#!/usr/bin/env bash
#
# Tests for base/post-create.sh.
#
# The script's collaborators (mise, nix, curl, sudo, nvim) are replaced with
# stubs that only record how they were called, so these tests never touch the
# network or the real toolchain.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
POST_CREATE="$REPO_ROOT/base/post-create.sh"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- stubs ------------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
for cmd in mise nix curl sudo nvim tmux; do
    cat > "$STUBS/$cmd" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> "$CALLS"
EOF
    chmod +x "$STUBS/$cmd"
done

# run_post_create <workspace> [VAR=value ...]
# Runs the script in <workspace> with a scrubbed environment. Sets the globals
# STATUS, CALLS_OUT and STDERR_OUT.
run_post_create() {
    local ws="$1"; shift
    local calls="$WORK/calls" err="$WORK/stderr"
    : > "$calls"
    mkdir -p "$WORK/home"
    STATUS=0
    (cd "$ws" && env -i HOME="$WORK/home" PATH="$STUBS:/usr/bin:/bin" CALLS="$calls" "$@" \
        bash "$POST_CREATE") >/dev/null 2>"$err" || STATUS=$?
    CALLS_OUT="$(cat "$calls")"
    STDERR_OUT="$(cat "$err")"
}

echo "post-create.sh tests"

# --- workspace with its own mise.toml ---------------------------------------
WS="$WORK/ws-with-config"
mkdir -p "$WS"
touch "$WS/mise.toml"
run_post_create "$WS"
[ "$STATUS" -eq 0 ] && ok "exits 0 with a workspace mise.toml" || bad "exited $STATUS"
assert_contains "$CALLS_OUT" "mise trust --yes mise.toml" "trusts the workspace mise.toml"
assert_contains "$CALLS_OUT" "mise install" "installs workspace tools"
assert_not_contains "$CALLS_OUT" "nvim" "does not sync nvim plugins (done at build time)"
assert_not_contains "$STDERR_OUT" "no longer needed" "no notice without INSTALL_* vars"

# --- bare workspace ---------------------------------------------------------
WS="$WORK/ws-bare"
mkdir -p "$WS"
run_post_create "$WS"
[ "$STATUS" -eq 0 ] && ok "exits 0 in a bare workspace" || bad "exited $STATUS"
assert_not_contains "$CALLS_OUT" "mise trust" "trusts nothing when no config exists"
assert_contains "$CALLS_OUT" "mise install" "still runs mise install"

# --- legacy INSTALL_* vars --------------------------------------------------
run_post_create "$WS" INSTALL_NIX=true INSTALL_DEVENV=true
[ "$STATUS" -eq 0 ] && ok "legacy INSTALL_* vars are not an error" || bad "exited $STATUS"
assert_contains "$STDERR_OUT" "INSTALL_NIX is no longer needed" "notice for INSTALL_NIX"
assert_contains "$STDERR_OUT" "INSTALL_DEVENV is no longer needed" "notice for INSTALL_DEVENV"
for cmd in nix curl sudo; do
    assert_not_contains "$CALLS_OUT" "$cmd " "does not call $cmd"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/tests/post-create.test.sh`
Expected: FAIL lines — at least "legacy INSTALL_* vars are not an error" (the current script sources a missing `nix.sh`), the two "notice for" assertions, and "does not call sudo".

- [ ] **Step 3: Rewrite `base/post-create.sh`**

```bash
#!/usr/bin/env bash
#
# post-create.sh — runs on container creation (the devcontainer
# postCreateCommand), from the workspace folder.
#
# The home toolchain, Nix, devenv and the tmux/nvim plugins are all baked into
# the image at build time (base/Dockerfile). This only does what needs the
# workspace to exist: its own mise config.
set -euo pipefail

# --- legacy opt-ins ---
for var in INSTALL_NIX INSTALL_DEVENV; do
  if [ -n "${!var:-}" ]; then
    echo "post-create.sh: ${var} is no longer needed -- Nix and devenv are always installed. You can remove it." >&2
  fi
done

# --- trust project mise config if present ---
if [ -f mise.toml ]; then
  mise trust --yes mise.toml || true
fi

if [ -f .config/mise/config.toml ]; then
  mise trust --yes .config/mise/config.toml || true
fi

# --- install workspace mise tools (the home toolchain is already present) ---
mise install
```

- [ ] **Step 4: Add the test to `mise.toml`** — in `[tasks.test]`, `run` becomes:

```toml
run = [
  "bash scripts/tests/sync-dotfiles.test.sh",
  "bash scripts/tests/mise-bump.test.sh",
  "bash scripts/tests/post-create.test.sh",
]
```

- [ ] **Step 5: Verify**

Run: `mise run check`
Expected: shellcheck clean; all three test files pass (`... passed, 0 failed`).

- [ ] **Step 6: Commit**

```bash
git add base/post-create.sh scripts/tests/post-create.test.sh mise.toml
git commit -m "feat(post-create): reduce to workspace-only mise setup"
```

---

### Task 2: Build Nix, devenv, user mise and the toolchain into the image

**Files:**
- Modify: `base/Dockerfile` (full rewrite, shown below)

**Interfaces:**
- Consumes: `base/post-create.sh` from Task 1 (copied into the image last).
- Produces (relied on by Tasks 3, 4, 6):
  - Cache mount ids `mise-downloads-${TARGETARCH}`, `mise-cache-${TARGETARCH}`, `npm-${TARGETARCH}` with the targets in Global Constraints, `uid=1000,gid=1000`.
  - Secret id `github_token`.
  - Build log line `==> mise downloaded (not served from cache):` followed by one path per newly downloaded file, relative to the downloads dir (e.g. `jq/1.8.2/...`).

- [ ] **Step 1: Replace `base/Dockerfile` with:**

```dockerfile
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
# that changed. CI persists the mounts across runners with buildkit-cache-dance
# (.github/workflows/devpod.yaml); the ids and targets must match there.
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
 && find "${MISE_DATA_DIR}/downloads" -type f | sort > /tmp/downloads-before \
 && MISE_ALWAYS_KEEP_DOWNLOAD=1 mise install \
 && find "${MISE_DATA_DIR}/downloads" -type f | sort > /tmp/downloads-after \
 && echo "==> mise downloaded (not served from cache):" \
 && comm -13 /tmp/downloads-before /tmp/downloads-after | sed "s|^${MISE_DATA_DIR}/downloads/||" \
 && rm /tmp/downloads-before /tmp/downloads-after \
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
```

- [ ] **Step 2: Self-check against the spec and Global Constraints** (no docker here). Confirm by reading:
  - The `/usr/local/bin/mise` install and `MISE_INSTALL_PATH=/usr/local/bin/mise` are gone.
  - The cache ids/targets match Global Constraints exactly.
  - The Nix layer comes before every `COPY` except `nix.conf`.
  - Run: `grep -n 'post-create' base/Dockerfile`. Expected: only the final `COPY`.

- [ ] **Step 3: Commit**

```bash
git add base/Dockerfile
git commit -m "feat(image): bake nix, devenv and a user-owned mise toolchain into the build"
```

---

### Task 3: Update `validate-devpod.sh` for the baked image

**Files:**
- Modify: `scripts/validate-devpod.sh`
- Modify: `mise.toml` (remove `[tasks.validate-devpod-devenv]`)

**Interfaces:**
- Consumes: image layout from Task 2.
- Produces: `scripts/validate-devpod.sh <image>` — exactly one positional argument; `EXPECT_ARCH` env as before. Task 4's workflow calls it this way.

- [ ] **Step 1: Header and argument handling.** Replace the header comment block and everything from `image="${1:-}"` through the end of the `case "$variant"` block with:

```bash
#!/usr/bin/env bash
# Validate that `devpod up` produces a working container from a dev image.
#
# Stands up a throwaway DevPod workspace whose devcontainer.json points at
# IMAGE, which runs the image's post-create.sh, then asserts the toolchain
# (baked in at build time, Nix and devenv included) is installed and actually
# runnable inside the container.
#
# Usage: scripts/validate-devpod.sh <image>
#   scripts/validate-devpod.sh dev:ci                    # a locally built tag
#   scripts/validate-devpod.sh ghcr.io/rahulmutt/dev:latest
#
# Set EXPECT_ARCH=amd64|arm64 to additionally assert the container's
# architecture, which is what stops CI from validating the wrong one.
set -euo pipefail

image="${1:-}"

if [ -z "$image" ]; then
  echo "usage: $0 <image>" >&2
  exit 2
fi
```

- [ ] **Step 2: Workspace id, devcontainer.json.**
  - Change `workspace_id="${DEVPOD_WORKSPACE_ID:-dev-validate-${variant}}"` to `workspace_id="${DEVPOD_WORKSPACE_ID:-dev-validate}"`.
  - Delete the `remote_env=...` lines and the `if [ "$variant" = "devenv" ]` block that follows them.
  - In the heredoc, replace the last two fields with the following (no `remoteEnv`, and no trailing comma):

```bash
  "remoteUser": "dev",
  "postCreateCommand": "post-create.sh"
}
JSON
```

- [ ] **Step 3: Smoke script.**
  - Remove the `printf 'variant="%s"\n' "$variant"` line.
  - Update the `# --- post-create.sh side effects ---` heading to `# --- build-time setup ---`.
  - Add these checks right after the `mise ls --missing` check:

```bash
mise_path="$(command -v mise || true)"
[ "$mise_path" = "$HOME/.local/bin/mise" ] &&
  pass "mise is the user install" ||
  fail "expected mise at $HOME/.local/bin/mise, got '${mise_path}'"

[ "$(stat -c %U "$HOME/.local/bin/mise" 2>/dev/null)" = "dev" ] &&
  pass "mise binary owned by dev" ||
  fail "$HOME/.local/bin/mise is not owned by dev"

[ ! -e /usr/local/bin/mise ] &&
  pass "no root-installed mise" ||
  fail "/usr/local/bin/mise still exists"
```

  Then replace the whole `# --- optional components ---` section with:

```bash
# --- nix + devenv (always installed) ---
# Resolved through the image's PATH, without sourcing nix.sh, as a
# non-interactive shell would.
nix --version >/dev/null 2>&1 && pass "nix" || fail "nix --version"
devenv version >/dev/null 2>&1 && pass "devenv" || fail "devenv version"
```

- [ ] **Step 4: `mise.toml`.** Delete the `[tasks.validate-devpod-devenv]` table. Then reword the comment above `[tasks.validate-devpod]` so it reads:

```toml
# Not part of `check`: these need docker and devpod, and build the image.
# CI runs the same steps per architecture (.github/workflows/devpod.yaml).
```

- [ ] **Step 5: Verify**

Run: `grep -n 'variant\|remoteEnv\|INSTALL_' scripts/validate-devpod.sh mise.toml; mise run check`
Expected: grep prints nothing; check passes.

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-devpod.sh mise.toml
git commit -m "test(devpod): validate the baked toolchain; drop the devenv variant"
```

---

### Task 4: CI — persist cache mounts, pass the GitHub token, drop the variant axis

**Files:**
- Modify: `.github/workflows/devpod.yaml`
- Modify: `.github/workflows/base.yaml` (build step)

**Interfaces:**
- Consumes: cache ids/targets and the `github_token` secret from Task 2; `validate-devpod.sh <image>` from Task 3.
- Produces: nothing downstream.

- [ ] **Step 1: `devpod.yaml` matrix.** Replace the `strategy:` block with:

```yaml
    strategy:
      # The legs fail for unrelated reasons, so let all of them report.
      fail-fast: false
      matrix:
        # Both architectures of the published manifest, on native runners:
        # emulating an arm64 `mise install` under QEMU would take far longer
        # than it takes to boot a real arm64 runner. Free for public repos.
        arch: [amd64, arm64]
        include:
          - arch: amd64
            runner: ubuntu-latest
          - arch: arm64
            runner: ubuntu-24.04-arm
```

  Change the job `name:` to `devpod up (linux/${{ matrix.arch }})`.

- [ ] **Step 2: `devpod.yaml` cache steps.** Insert these steps between "Set up Docker Buildx" and "Build image":

```yaml
      # The Dockerfile's `mise install` keeps downloaded archives in BuildKit
      # cache mounts, which a fresh runner doesn't have. Restore them from the
      # Actions cache, falling back to the previous config's entry on a bump so
      # only the bumped tool downloads.
      - name: Restore BuildKit cache mounts
        id: mounts-cache
        uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}/buildkit-mounts
          key: buildkit-mounts-${{ matrix.arch }}-${{ hashFiles('.config/mise/config.toml') }}
          restore-keys: buildkit-mounts-${{ matrix.arch }}-

      # Injects the restored dirs into the mounts before the build, and (post
      # step, which runs before actions/cache saves) extracts them after.
      # The ids and targets must match the RUN --mount flags in base/Dockerfile.
      - name: Inject BuildKit cache mounts
        uses: reproducible-containers/buildkit-cache-dance@5422eac04292c961a382e0f584ea0f03ad9da723 # v3.4.0
        with:
          skip-extraction: ${{ steps.mounts-cache.outputs.cache-hit }}
          cache-map: |
            {
              "${{ runner.temp }}/buildkit-mounts/mise-downloads": {
                "target": "/home/dev/.local/share/mise/downloads",
                "id": "mise-downloads-${{ matrix.arch }}", "uid": "1000", "gid": "1000"
              },
              "${{ runner.temp }}/buildkit-mounts/mise-cache": {
                "target": "/home/dev/.cache/mise",
                "id": "mise-cache-${{ matrix.arch }}", "uid": "1000", "gid": "1000"
              },
              "${{ runner.temp }}/buildkit-mounts/npm": {
                "target": "/home/dev/.npm",
                "id": "npm-${{ matrix.arch }}", "uid": "1000", "gid": "1000"
              }
            }
```

- [ ] **Step 3: `devpod.yaml` build + validate.**
  - In "Build image", add under `with:`:

    ```yaml
              # Authenticates mise's GitHub API calls (60 req/hour unauthenticated).
              secrets: github_token=${{ secrets.GITHUB_TOKEN }}
    ```

  - In "Validate devpod up", change the run line to `run: scripts/validate-devpod.sh "${IMAGE}"`.

- [ ] **Step 4: `base.yaml`.** In "Build and push Docker image", add under `with:` (after `labels:`):

```yaml
          # Only needed on a layer-cache miss, when `mise install` really runs.
          secrets: github_token=${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 5: Verify**

Run: `grep -n 'variant' .github/workflows/*.yaml; mise x actionlint@1.7.12 -- actionlint .github/workflows/devpod.yaml .github/workflows/base.yaml && echo LINT_OK`
Expected: grep prints nothing; `LINT_OK` (actionlint also runs shellcheck on `run:` blocks).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/devpod.yaml .github/workflows/base.yaml
git commit -m "ci: persist mise download cache across runners; drop devenv matrix axis"
```

---

### Task 5: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Usage section.** Replace the paragraph starting `The \`post-create.sh\` step (baked into the image)` with:

```markdown
The toolchain, Nix, devenv and the tmux/nvim plugins are all installed when the
image is built, so a new container is ready immediately. The `post-create.sh`
step (baked into the image) only trusts and installs the workspace's own
`mise.toml`, if it has one.
```

- [ ] **Step 2: "What's inside".**
  - After the **Toolchain** bullet, add:

    ```markdown
    - **Nix + devenv:** single-user [Nix](https://nixos.org/) and
      [devenv](https://devenv.sh/), always installed.
    ```

  - In the **Toolchain** bullet, change "managed by [mise]" to "managed by a user-installed [mise]".

- [ ] **Step 3: Configuration.** Replace the whole `### Optional components (environment variables)` subsection (heading, table and example) with:

```markdown
### Nix and devenv

Both are always installed. The `INSTALL_NIX` and `INSTALL_DEVENV` variables
that used to opt into them are no longer needed; if set, `post-create.sh` just
prints a reminder to remove them.
```

  Replace the "Toolchain versions" body with:

```markdown
Pin or change tool versions by editing `.config/mise/config.toml`; the image
build runs `mise install` against it. Downloaded archives are kept in BuildKit
cache mounts (persisted across CI runners), so bumping one pin downloads only
that tool.
```

- [ ] **Step 4: Development section.**
  - Delete the paragraph "The script takes an optional variant:", the code block after it, and the paragraph starting "The `devenv` variant sets".
  - In the `validate-devpod` paragraph, change "running the real `post-create.sh`" to "running the real `post-create.sh` on the built image". Also add "Nix and devenv" to the list of things it asserts.
  - In the CI paragraph, change "as an `[amd64, arm64] x [default, devenv]` matrix" to "once per architecture (`amd64`, `arm64`)".
  - Add this sentence at the end of the CI paragraph: "The build's mise download cache is carried between runners with `buildkit-cache-dance`, so a one-pin bump downloads one tool."

- [ ] **Step 5: Verify**

Run: `grep -n 'INSTALL_\|variant\|devenv\]' README.md`
Expected: only the line in the new "Nix and devenv" subsection mentioning `INSTALL_NIX`/`INSTALL_DEVENV`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: describe the build-time toolchain and always-on nix/devenv"
```

---

### Task 6: Verify the image and the cache in CI

No container runtime is available locally, so this runs on GitHub Actions.

- [ ] **Step 1: Ask the user for permission** to push the branch and open a draft PR. Pushing triggers `check.yaml` → `devpod.yaml`. If they decline, stop here and report that Tasks 1–5 are unverified against a real build.

- [ ] **Step 2: Push and open a draft PR**

```bash
git push -u origin HEAD
gh pr create --draft --title "Bake the toolchain into the image" --body "Implements docs/superpowers/specs/2026-10-02-bake-toolchain-into-image-design.md"
```

- [ ] **Step 3: Run 1 (cold).** Wait for the checks with `gh pr checks --watch`.
  - Expected: `Check` passes and both `devpod up (linux/amd64|arm64)` legs pass.
  - In each leg's "Build image" log, the `==> mise downloaded` list should cover every tool. This is the cold baseline.
  - On failure, use superpowers:systematic-debugging. Don't paper over it.

- [ ] **Step 4: Run 2 (one-pin bump).**
  - Change exactly one pin in `.config/mise/config.toml` to another real release, e.g. `jq = "1.8.1"`. Check that it exists with `mise ls-remote jq`.
  - Commit `test: single-pin cache check (revert me)` and push.
  - Expected:
    - Both legs pass.
    - "Restore BuildKit cache mounts" reports a restore from the `restore-keys` prefix.
    - In each leg, the `==> mise downloaded` list contains only `jq/...` entries.
  - If other tools show up, stop and report back to the user, naming the backend each extra tool uses (`mise ls --json`). The spec requires revisiting the design in that case, not working around it.

- [ ] **Step 5: Revert the test bump**

```bash
git revert --no-edit HEAD
git push
```

  Expected: checks pass again.

- [ ] **Step 6: Report.** Give the user:
  - The PR link.
  - The two download lists from runs 1 and 2.
  - The compressed image size per arch from the PR build vs `main`. Read it with `docker buildx imagetools inspect --raw` on any machine that has docker, or skip it and say so.
