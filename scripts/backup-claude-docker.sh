#!/usr/bin/env bash
set -euo pipefail

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI=podman
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI=docker
else
    echo "Neither podman nor docker found"
    exit 1
fi

POD_NAME="${1:?usage: $0 <container-name> [remote-dir]}"

REMOTE_DIR="${2:-$(
    "$CONTAINER_CLI" exec "$POD_NAME" sh -c 'printf "%s" "$HOME/.claude/projects"'
)}"

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OUT_FILE="${POD_NAME}-claude-projects-${TIMESTAMP}.zip"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Using: $CONTAINER_CLI"
echo "Copying ${POD_NAME}:${REMOTE_DIR}"

"$CONTAINER_CLI" cp \
    "${POD_NAME}:${REMOTE_DIR}" \
    "${TMP_DIR}/projects"

echo "Creating ${OUT_FILE}"

(
    cd "$TMP_DIR"
    zip -qr "$OLDPWD/$OUT_FILE" projects
)

echo "Created: $OUT_FILE"
