#!/usr/bin/env bash
# nuke.sh [profile]  — DELETE the Lima VM entirely. Destroys the disk image.
#
# Mounted Mac directories are NOT affected. Only the VM's internal state is
# destroyed: installed packages, ~/.cargo, ~/.claude login, shell history.

set -euo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

resolve_profile "${1:-}"
load_env

echo "About to DELETE Lima VM '$VM_NAME' (profile: $PROFILE)."
echo "Mounted Mac directories are safe. VM-internal state (installed packages,"
echo "cargo cache, agent logins, shell history) will be destroyed."
read -r -p "Type the VM name to confirm: " confirm

if [ "$confirm" != "$VM_NAME" ]; then
  echo "[devbox:$PROFILE] name mismatch — aborting."
  exit 1
fi

limactl stop --force "$VM_NAME" 2>/dev/null || true
limactl delete "$VM_NAME"
echo "[devbox:$PROFILE] '$VM_NAME' deleted. Recreate with: ./up.sh $([ "$PROFILE" = devbox ] || echo "$PROFILE")"
