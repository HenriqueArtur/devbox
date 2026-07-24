#!/usr/bin/env bash
# nuke.sh — DELETE the Lima VM entirely. Destroys the disk image.
#
# Your projects (mounted from the Mac) are NOT affected. Only the VM's own
# state is destroyed: installed packages, ~/.cargo, ~/.claude login, shell
# history, etc.

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

echo "About to DELETE Lima VM '$VM_NAME'."
echo "Mounted Mac directories are safe. VM-internal state (installed packages,"
echo "cargo cache, agent logins, shell history) will be destroyed."
read -r -p "Type the VM name to confirm: " confirm

if [ "$confirm" != "$VM_NAME" ]; then
  echo "[devbox] name mismatch — aborting."
  exit 1
fi

limactl stop --force "$VM_NAME" 2>/dev/null || true
limactl delete "$VM_NAME"
echo "[devbox] '$VM_NAME' deleted. Run ./up.sh to create a fresh one."
