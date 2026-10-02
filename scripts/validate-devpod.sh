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

if ! command -v devpod >/dev/null 2>&1; then
  echo "devpod not found: https://devpod.sh/docs/getting-started/install" >&2
  exit 2
fi

workspace_id="${DEVPOD_WORKSPACE_ID:-dev-validate}"
workspace_dir="$(mktemp -d)"

# Every binary the image is expected to ship. Each is *run*, not merely resolved
# on PATH: mise puts a shim on PATH for each configured tool, so a shim pointing
# at a broken or wrong-arch install still resolves. Executing it does not.
tools=(
  # apt layer (base/Dockerfile)
  git curl sudo chromium
  # mise-managed toolchain (.config/mise/config.toml)
  mise rg fd fzf jq bat glow btop lazygit gh tmux tree-sitter nvim
  node bun python dprint ttyd ast-grep
  # AI coding agents
  claude codex opencode pi codeburn skills vsync nono
)

cleanup() {
  devpod delete "$workspace_id" --force --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$workspace_dir"
}
trap cleanup EXIT

# A synthetic devcontainer.json rather than the repo's own: that one pins a
# published sha- tag, and the whole point here is to test the image we were
# handed. Keep these fields in step with the example in the README, since this
# is the config an end user is expected to copy.
mkdir -p "$workspace_dir/.devcontainer"
cat > "$workspace_dir/.devcontainer/devcontainer.json" <<JSON
{
  "name": "dev-validate",
  "image": "${image}",
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "post-create.sh"
}
JSON

# Proves the workspace source really lands in workspaceFolder.
echo "devpod-validate" > "$workspace_dir/marker.txt"

echo "==> devpod up (image: ${image})"
devpod up "$workspace_dir" \
  --id "$workspace_id" \
  --provider docker \
  --ide none \
  --debug

echo "==> smoke testing the container"

# `devpod ssh --command` takes a single string, so ship the checks as base64 to
# keep quoting and newlines out of the equation.
smoke_script="$(
  printf 'tools="%s"\n' "${tools[*]}"
  printf 'expect_arch="%s"\n' "${EXPECT_ARCH:-}"
  cat <<'REMOTE'
set -u

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

# --- architecture ---
# Without this, a mis-wired matrix would run an "arm64" leg against an amd64
# container and still go green.
if [ -n "$expect_arch" ]; then
  case "$expect_arch" in
    amd64) want="x86_64" ;;
    arm64) want="aarch64" ;;
    *) want="$expect_arch" ;;
  esac

  got="$(uname -m)"
  [ "$got" = "$want" ] &&
    pass "architecture is $got ($expect_arch)" ||
    fail "expected $want for $expect_arch, container is $got"
fi

# --- identity and workspace layout ---
user="$(id -un)"
[ "$user" = "dev" ] && pass "user is dev" || fail "expected user dev, got $user"

[ -f /workspace/marker.txt ] &&
  pass "workspace source is at /workspace" ||
  fail "/workspace/marker.txt missing - workspace source did not land in workspaceFolder"

sudo -n true 2>/dev/null && pass "passwordless sudo" || fail "passwordless sudo not working"

# --- build-time setup ---
[ -d "$HOME/.tmux/plugins/tpm" ] && pass "tmux plugins installed" || fail "tmux tpm missing"
[ -d "$HOME/.local/share/nvim/lazy" ] && pass "nvim plugins installed" || fail "nvim lazy plugins missing"

missing="$(mise ls --missing 2>/dev/null || true)"
[ -z "$missing" ] && pass "mise reports no missing tools" || fail "mise is missing tools: $missing"

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

# --- every tool runs ---
for tool in $tools; do
  case "$tool" in
    tmux) flag="-V" ;;  # tmux has no --version
    *) flag="--version" ;;
  esac

  if "$tool" "$flag" >/dev/null 2>&1; then
    pass "$tool"
  else
    fail "$tool $flag"
  fi
done

# --- nix + devenv (always installed) ---
# Resolved through the image's PATH, without sourcing nix.sh, as a
# non-interactive shell would.
nix --version >/dev/null 2>&1 && pass "nix" || fail "nix --version"
devenv version >/dev/null 2>&1 && pass "devenv" || fail "devenv version"

if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi

echo "SMOKE_TEST_OK"
REMOTE
)"

log="${workspace_dir}/smoke.log"
encoded="$(printf '%s' "$smoke_script" | base64 | tr -d '\n')"

devpod ssh "$workspace_id" --command "echo ${encoded} | base64 -d | bash" | tee "$log"

# Belt and braces: devpod ssh should propagate the remote exit code (set -o
# pipefail makes that this pipeline's status), but require the sentinel too, so
# a swallowed exit code cannot pass as success.
if ! grep -q "SMOKE_TEST_OK" "$log"; then
  echo "==> devpod validation FAILED"
  exit 1
fi

echo "==> devpod validation passed"
