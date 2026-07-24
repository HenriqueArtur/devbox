#!/usr/bin/env bash
# doctor.sh — run devbox-doctor inside the VM from the Mac.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/devbox.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "[doctor] $ENV_FILE not found." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${VM_NAME:?VM_NAME not set in devbox.env}"

if ! limactl list --quiet | grep -qx "$VM_NAME"; then
  echo "[doctor] VM '$VM_NAME' does not exist. Run ./up.sh first." >&2
  exit 2
fi

status="$(limactl list --format '{{.Status}}' "$VM_NAME" 2>/dev/null || echo "")"
if [ "$status" != "Running" ]; then
  echo "[doctor] VM '$VM_NAME' status is '$status'. Run ./up.sh first." >&2
  exit 2
fi

# Pass expected versions as env vars so the doctor can compare against the
# pinned values in devbox.env (source of truth for the machine).
exec limactl shell "$VM_NAME" env \
  EXPECTED_RUST_VERSION="$RUST_VERSION" \
  EXPECTED_NODE_VERSION="$NODE_VERSION" \
  EXPECTED_LAZYGIT_VERSION="$LAZYGIT_VERSION" \
  devbox-doctor "$@"
