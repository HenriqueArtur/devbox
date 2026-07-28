#!/usr/bin/env bash
# _lib.sh — shared helpers sourced by up.sh / down.sh / nuke.sh / doctor.sh.
#
# Profile model:
#   ./up.sh              → profile "devbox"           → devbox.env         → devbox.yaml
#   ./up.sh sunne        → profile "sunne"            → devbox.sunne.env   → devbox.sunne.yaml
#   ./up.sh personal     → profile "personal"         → devbox.personal.env → devbox.personal.yaml
#
# The default (no-arg) profile keeps the historical filenames so existing
# muscle memory and existing devbox.env files keep working.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set PROFILE, ENV_FILE, OUT_FILE from optional first CLI arg.
# Falls back to profile "devbox" when no argument is given.
resolve_profile() {
  PROFILE="${1:-devbox}"

  if [ "$PROFILE" = "devbox" ]; then
    ENV_FILE="$REPO_DIR/devbox.env"
    OUT_FILE="$REPO_DIR/devbox.yaml"
  else
    ENV_FILE="$REPO_DIR/devbox.$PROFILE.env"
    OUT_FILE="$REPO_DIR/devbox.$PROFILE.yaml"
  fi
}

# Load the resolved env file. Enforces mandatory VM_NAME.
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "[devbox] $ENV_FILE not found." >&2
    if [ "$PROFILE" != "devbox" ]; then
      echo "[devbox] Copy devbox.env.example to devbox.$PROFILE.env and edit it." >&2
    else
      echo "[devbox] Copy devbox.env.example to devbox.env and edit it." >&2
    fi
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  : "${VM_NAME:?VM_NAME not set in $ENV_FILE}"
}
