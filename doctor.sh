#!/usr/bin/env bash
# doctor.sh [profile] [--verbose]  — run devbox-doctor inside the VM.

set -euo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# First positional arg is the profile IF it is not a flag. Otherwise fall
# back to the default profile and pass everything through to devbox-doctor.
PROFILE_ARG=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  PROFILE_ARG="$1"
  shift
fi

resolve_profile "$PROFILE_ARG"
load_env

if ! limactl list --quiet | grep -qx "$VM_NAME"; then
  echo "[doctor:$PROFILE] VM '$VM_NAME' does not exist. Run ./up.sh $([ "$PROFILE" = devbox ] || echo "$PROFILE") first." >&2
  exit 2
fi

st="$(limactl list --format '{{.Status}}' "$VM_NAME" 2>/dev/null || echo "")"
if [ "$st" != "Running" ]; then
  echo "[doctor:$PROFILE] VM '$VM_NAME' status is '$st'. Run ./up.sh $([ "$PROFILE" = devbox ] || echo "$PROFILE") first." >&2
  exit 2
fi

# An unpinned flyctl has no expected version to compare against — passing
# "latest" through would make every check warn about a version mismatch.
EXPECTED_FLYCTL_VERSION="${FLYCTL_VERSION:-latest}"
[ "$EXPECTED_FLYCTL_VERSION" = "latest" ] && EXPECTED_FLYCTL_VERSION=""

# Pass pinned versions so devbox-doctor can flag drift against devbox.env.
exec limactl shell "$VM_NAME" env \
  EXPECTED_RUST_VERSION="$RUST_VERSION" \
  EXPECTED_NODE_VERSION="$NODE_VERSION" \
  EXPECTED_LAZYGIT_VERSION="$LAZYGIT_VERSION" \
  EXPECTED_INSTALL_FLYCTL="${INSTALL_FLYCTL:-0}" \
  EXPECTED_FLYCTL_VERSION="$EXPECTED_FLYCTL_VERSION" \
  devbox-doctor "$@"
