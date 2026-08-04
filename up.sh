#!/usr/bin/env bash
# up.sh [profile]  — render the Lima YAML from the template and start the VM.
#
# Profile defaults to "devbox". See _lib.sh for the file-naming convention.

set -euo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

resolve_profile "${1:-}"
load_env

TMPL_FILE="$REPO_DIR/devbox.yaml.tmpl"
if [ ! -f "$TMPL_FILE" ]; then
  echo "[devbox] $TMPL_FILE missing." >&2
  exit 1
fi

# Validate mount source directories exist on the Mac.
if [ ! -d "$DEV_ROOT" ]; then
  echo "[devbox] DEV_ROOT=$DEV_ROOT does not exist. Create it before starting the VM." >&2
  exit 1
fi

# STATE_ROOT holds VM state that must outlive the VM disk (Claude Code
# sessions + login). Unlike DEV_ROOT it is devbox-owned, so we create it
# instead of erroring. Defaulted here as well, so profile .env files written
# before this feature existed keep rendering a valid template.
STATE_ROOT="${STATE_ROOT:-$HOME/.devbox/state/$VM_NAME}"
export STATE_ROOT
mkdir -p "$STATE_ROOT/claude"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/claude"

# Render template into the profile-specific output file.
if ! command -v envsubst >/dev/null 2>&1; then
  echo "[devbox] envsubst not found. Install gettext: brew install gettext" >&2
  exit 1
fi
# Per-profile opt-ins get explicit defaults so the rendered YAML never carries
# an empty value for them.
export INSTALL_FLYCTL="${INSTALL_FLYCTL:-0}"
export FLYCTL_VERSION="${FLYCTL_VERSION:-latest}"

envsubst < "$TMPL_FILE" > "$OUT_FILE"
echo "[devbox:$PROFILE] rendered $OUT_FILE"

# Start (or restart) the VM.
FRESH=0
if limactl list --quiet | grep -qx "$VM_NAME"; then
  echo "[devbox:$PROFILE] VM '$VM_NAME' exists; starting if stopped"
  limactl start "$VM_NAME"
else
  echo "[devbox:$PROFILE] creating VM '$VM_NAME'"
  limactl start --name="$VM_NAME" "$OUT_FILE"
  FRESH=1
fi

# On fresh provisioning, provision.sh writes ~/.provision-done as its LAST
# step. If missing after start, provisioning died partway through.
if [ "$FRESH" = "1" ]; then
  if ! limactl shell "$VM_NAME" -- test -f '.provision-done' 2>/dev/null; then
    echo >&2
    echo "[devbox:$PROFILE] ERROR: provisioning did not complete." >&2
    echo "[devbox:$PROFILE] The sentinel ~/.provision-done is missing inside the VM." >&2
    echo "[devbox:$PROFILE] Check the cloud-init log inside the VM:" >&2
    echo "[devbox:$PROFILE]   limactl shell $VM_NAME -- sudo tail -80 /var/log/cloud-init-output.log" >&2
    echo "[devbox:$PROFILE] Then re-run ./up.sh $PROFILE (provision is idempotent)" >&2
    echo "[devbox:$PROFILE]   or ./nuke.sh $PROFILE && ./up.sh $PROFILE." >&2
    exit 1
  fi

  # Restart from outside so `sudo usermod -aG docker $USER` takes effect in
  # every future shell (doing it from inside cloud-init races Lima's own
  # start-up state machine).
  echo "[devbox:$PROFILE] activating docker group (VM restart)"
  limactl stop "$VM_NAME"
  limactl start "$VM_NAME"
fi

echo "[devbox:$PROFILE] enter with: limactl shell $VM_NAME"
if [ "$PROFILE" = "devbox" ]; then
  echo "[devbox:$PROFILE] verify:     ./doctor.sh"
else
  echo "[devbox:$PROFILE] verify:     ./doctor.sh $PROFILE"
fi
