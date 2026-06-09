#!/usr/bin/env bash
set -euo pipefail

POD_NAME="${1:?usage: $0 <pod-or-container-name> [remote-dir]}"
REMOTE_DIR="${2:-/root/.claude/projects}"

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OUT_FILE="${POD_NAME}-claude-projects-${TIMESTAMP}.zip"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Copying ${POD_NAME}:${REMOTE_DIR} ..."
docker cp "${POD_NAME}:${REMOTE_DIR}" "${TMP_DIR}/projects"

echo "Creating ${OUT_FILE} ..."
(
  cd "$TMP_DIR"
  zip -qr "$OLDPWD/$OUT_FILE" projects
)

echo "Created: $OUT_FILE"
