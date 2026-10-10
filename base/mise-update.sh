#!/usr/bin/env bash
#
# mise-update — update mise and the toolchain, then run a command.
#
#   mise-update                  # update, then exit
#   mise-update claude --resume  # update, then exec `claude --resume`
#
# Runs `mise self-update`, then `mise upgrade --interactive --bump`. A failed
# or cancelled update only warns, so the wrapped command still runs offline.
set -euo pipefail

# Like post-create.sh, this may run without the image's ENV PATH
# (base/Dockerfile), e.g. under DevPod's Kubernetes provider.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

status=0
mise self-update && mise upgrade --interactive --bump || status=$?
if [ "$status" -ne 0 ]; then
  echo "mise-update: update failed (exit ${status}), continuing" >&2
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi
