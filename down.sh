#!/usr/bin/env bash
# down.sh — stop the Lima VM without deleting it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/devbox.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "[devbox] $ENV_FILE not found." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${VM_NAME:?VM_NAME not set in devbox.env}"

limactl stop "$VM_NAME"
echo "[devbox] '$VM_NAME' stopped. State is preserved; run ./up.sh to resume."
