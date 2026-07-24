#!/usr/bin/env bash
# up.sh — render devbox.yaml from the template and start the Lima VM.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/devbox.env"
TMPL_FILE="$REPO_DIR/devbox.yaml.tmpl"
OUT_FILE="$REPO_DIR/devbox.yaml"

if [ ! -f "$ENV_FILE" ]; then
  echo "[devbox] $ENV_FILE not found. Copy devbox.env.example to devbox.env and edit it." >&2
  exit 1
fi

if [ ! -f "$TMPL_FILE" ]; then
  echo "[devbox] $TMPL_FILE missing." >&2
  exit 1
fi

# Load env vars.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${VM_NAME:?VM_NAME not set in devbox.env}"

# Validate mount source directories exist.
for var in DEV_ROOT WIKI_ROOT; do
  path="${!var}"
  if [ ! -d "$path" ]; then
    echo "[devbox] $var=$path does not exist. Create it before starting the VM." >&2
    exit 1
  fi
done

# Render template.
if ! command -v envsubst >/dev/null 2>&1; then
  echo "[devbox] envsubst not found. Install gettext: brew install gettext" >&2
  exit 1
fi
envsubst < "$TMPL_FILE" > "$OUT_FILE"
echo "[devbox] rendered $OUT_FILE"

# Start (or restart) the VM.
FRESH=0
if limactl list --quiet | grep -qx "$VM_NAME"; then
  echo "[devbox] VM '$VM_NAME' exists; starting if stopped"
  limactl start "$VM_NAME"
else
  echo "[devbox] creating VM '$VM_NAME'"
  limactl start --name="$VM_NAME" "$OUT_FILE"
  FRESH=1
fi

# On fresh provisioning, provision.sh runs `sudo reboot` at the end so the
# `docker` group membership (from `usermod -aG docker`) actually takes effect
# in every future shell. Wait for the VM to come back before returning.
#
# Detection: the sentinel /home/<user>/.provision-done is written by provision.sh
# right before it reboots. If we see it and the VM is not running, we know
# a reboot is in progress and we wait it out.
if [ "$FRESH" = "1" ]; then
  # Sanity check: provision.sh touches ~/.provision-done as its LAST step.
  # If that sentinel is missing, provisioning died partway through (usually
  # a transient GitHub / apt failure). Fail loudly instead of pretending the
  # VM is ready.
  if ! limactl shell "$VM_NAME" -- test -f '.provision-done' 2>/dev/null; then
    echo >&2
    echo "[devbox] ERROR: provisioning did not complete." >&2
    echo "[devbox] The sentinel ~/.provision-done is missing inside the VM." >&2
    echo "[devbox] Check the cloud-init log inside the VM:" >&2
    echo "[devbox]   limactl shell $VM_NAME -- sudo tail -80 /var/log/cloud-init-output.log" >&2
    echo "[devbox] Then re-run ./up.sh (provision.sh is idempotent) or ./nuke.sh && ./up.sh." >&2
    exit 1
  fi

  # Restart the VM so `sudo usermod -aG docker $USER` from provision.sh takes
  # effect in every future shell. Doing this from OUTSIDE the VM (rather than
  # `sudo reboot` from inside cloud-init) avoids racing Lima's own start-up
  # state machine.
  echo "[devbox] activating docker group (VM restart)"
  limactl stop "$VM_NAME"
  limactl start "$VM_NAME"
fi

echo "[devbox] enter with: limactl shell $VM_NAME"
echo "[devbox] verify:     ./doctor.sh"
