#!/usr/bin/env bash
# down.sh [profile]  — stop the Lima VM for the given profile without deleting it.

set -euo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

resolve_profile "${1:-}"
load_env

limactl stop "$VM_NAME"
echo "[devbox:$PROFILE] '$VM_NAME' stopped. Resume with: ./up.sh $([ "$PROFILE" = devbox ] || echo "$PROFILE")"
