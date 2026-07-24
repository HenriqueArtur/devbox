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
if limactl list --quiet | grep -qx "$VM_NAME"; then
  echo "[devbox] VM '$VM_NAME' exists; starting if stopped"
  limactl start "$VM_NAME"
else
  echo "[devbox] creating VM '$VM_NAME'"
  limactl start --name="$VM_NAME" "$OUT_FILE"
fi

echo "[devbox] enter with: limactl shell $VM_NAME"
