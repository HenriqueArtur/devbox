#!/usr/bin/env bash
# provision.sh — runs inside the Lima VM on first boot (as the Lima user).
# Idempotent: safe to re-run to sync the VM after a template change.
#
# Reads env vars set in devbox.yaml (RUST_VERSION, NODE_VERSION, etc).

set -euxo pipefail

log() { echo "[provision] $*"; }

: "${RUST_VERSION:?RUST_VERSION not set}"
: "${NODE_VERSION:?NODE_VERSION not set}"
: "${LAZYGIT_VERSION:?LAZYGIT_VERSION not set}"
: "${DOTFILES_REPO:?DOTFILES_REPO not set}"
: "${NVIM_CONFIG_REPO:?NVIM_CONFIG_REPO not set}"

REPOS_DIR="$HOME/repos"
mkdir -p "$REPOS_DIR"

# --- Default shell = zsh -----------------------------------------------------
# Lima's virtual user (username_guest) defaults to /bin/bash. Our dotfiles
# target zsh, and `mise activate` in .zshrc is what puts npm-installed
# binaries (claude, etc) on PATH.
CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "/usr/bin/zsh" ]; then
  log "setting default shell to zsh for $USER"
  sudo chsh -s /usr/bin/zsh "$USER"
fi

# --- Convenience symlinks to Mac-side mounts --------------------------------
# ~/projects  → /mnt/dev   (your code)
# ~/wiki      → /mnt/wiki  (ai-memory's shared wiki)
ln -sfn /mnt/dev  "$HOME/projects"
ln -sfn /mnt/wiki "$HOME/wiki"

# --- Enable unprivileged user namespaces (required by ai-jail's bwrap) ------
# Ubuntu 24.04's default AppArmor policy denies user-namespace creation for
# unprivileged users. Every tool that uses rootless user namespaces breaks:
# ai-jail (bwrap), rootless podman, flatpak, distrobox. We're inside a
# dedicated Lima VM — the extra isolation is redundant with the VM boundary.
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" != "0" ]; then
  log "relaxing apparmor_restrict_unprivileged_userns (bwrap needs it)"
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
    | sudo tee /etc/sysctl.d/60-userns.conf >/dev/null
  sudo sysctl --system >/dev/null
fi

# --- Rust (pinned) -----------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
  log "installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf --retry 5 --retry-delay 5 --retry-all-errors \
    --max-time 120 https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain "$RUST_VERSION" --profile minimal
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustup toolchain install "$RUST_VERSION" --profile minimal
rustup default "$RUST_VERSION"
rustup component add rust-analyzer clippy rustfmt

# --- mise + Node (pinned) ----------------------------------------------------
if ! command -v mise >/dev/null 2>&1; then
  log "installing mise"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 120 \
    https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
eval "$(mise activate bash)"
mise use -g "node@${NODE_VERSION}"

# --- Neovim (LazyVim needs >=0.10; Ubuntu 24.04 ships 0.9.5) ----------------
if ! command -v nvim >/dev/null 2>&1 || \
   [ "$(nvim --version | head -1 | awk '{print $2}' | tr -d 'v')" \< "0.10.0" ]; then
  log "installing neovim (appimage)"
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  nvim_url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage" ;;
    aarch64) nvim_url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.appimage" ;;
    *) log "unsupported arch for nvim: $arch"; exit 1 ;;
  esac
  sudo curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
    -o /usr/local/bin/nvim "$nvim_url"
  sudo chmod +x /usr/local/bin/nvim
fi

# --- lazygit (pinned; nvim-config expects a specific version) ---------------
lazygit_installed=""
if command -v lazygit >/dev/null 2>&1; then
  lazygit_installed="$(lazygit --version 2>/dev/null | grep -oE 'version=[0-9.]+' | head -1 | cut -d= -f2 || true)"
fi
if [ "$lazygit_installed" != "$LAZYGIT_VERSION" ]; then
  log "installing lazygit ${LAZYGIT_VERSION}"
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  lg_arch="x86_64" ;;
    aarch64) lg_arch="arm64" ;;
    *) log "unsupported arch for lazygit: $arch"; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 -o "$tmp/lg.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${lg_arch}.tar.gz"
  tar -xf "$tmp/lg.tar.gz" -C "$tmp" lazygit
  mkdir -p "$HOME/.local/bin"
  install "$tmp/lazygit" "$HOME/.local/bin/lazygit"
  rm -rf "$tmp"
fi

# --- Docker Engine (needed by akitaonrails/ai-memory) -----------------------
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker engine"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
fi

# --- dotfiles ----------------------------------------------------------------
DOTFILES_DIR="$REPOS_DIR/dotfiles"
if [ ! -d "$DOTFILES_DIR" ]; then
  log "cloning dotfiles"
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi
( cd "$DOTFILES_DIR" && ./install.sh --force )

# --- nvim-config -------------------------------------------------------------
NVIM_CONFIG_DIR="$REPOS_DIR/nvim-config"
if [ ! -d "$NVIM_CONFIG_DIR" ]; then
  log "cloning nvim-config"
  git clone "$NVIM_CONFIG_REPO" "$NVIM_CONFIG_DIR"
fi
# nvim-config's installer re-runs apt for a set of deps we already installed
# above. Its non-zero exit is not fatal — the symlink step (which is what we
# actually need) still runs.
( cd "$NVIM_CONFIG_DIR" && ./install.sh || true )

# --- ai-jail (from cargo) ----------------------------------------------------
if ! command -v ai-jail >/dev/null 2>&1; then
  log "installing ai-jail"
  sudo apt-get install -y bubblewrap
  cargo install ai-jail
fi

# --- ai-memory (akitaonrails, Docker-wrapped) --------------------------------
# The crate `ai-memory` on crates.io is a different unrelated tool. The one
# we want is akitaonrails/ai-memory, distributed as a shell wrapper that
# runs the server in Docker.
if [ ! -f "$HOME/.local/bin/ai-memory" ]; then
  log "installing ai-memory wrapper (akitaonrails/ai-memory)"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
    -o "$HOME/.local/bin/ai-memory" \
    https://raw.githubusercontent.com/akitaonrails/ai-memory/main/bin/ai-memory
  chmod +x "$HOME/.local/bin/ai-memory"
fi

# --- Claude Code CLI ---------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  log "installing claude code cli"
  npm install -g @anthropic-ai/claude-code
fi

# --- ai-memory server + Claude Code integration -----------------------------
# Server runs as a Docker container bound to loopback (127.0.0.1:49374).
# Data lives on the Mac side via the mounted /mnt/wiki, so nuke+up of the VM
# preserves everything ai-memory remembers.
#
# Zero-LLM / zero-embedding mode: FTS5 search works; no consolidation or
# semantic handoffs until we add an LLM provider env var.
if ! sudo docker ps --format '{{.Names}}' | grep -qx ai-memory; then
  log "starting ai-memory docker container"
  sudo docker pull akitaonrails/ai-memory:latest
  # Ensure Mac-side wiki dir looks like something ai-memory can own.
  # Container runs as its own uid; we relax perms on the mount point only.
  chmod 0777 /mnt/wiki 2>/dev/null || true
  sudo docker run -d --name ai-memory \
    --restart unless-stopped \
    -p 127.0.0.1:49374:49374 \
    -v /mnt/wiki:/data \
    akitaonrails/ai-memory:latest
fi

# `install-mcp` / `install-hooks` are idempotent (they replace the ai-memory
# entry, keep everything else, and back up the file with a .bak-<ts> suffix).
if command -v ai-memory >/dev/null 2>&1; then
  log "registering ai-memory MCP + lifecycle hooks with Claude Code"
  ai-memory install-mcp   --client claude-code --apply || \
    log "warning: install-mcp failed (server may still be starting)"
  ai-memory install-hooks --agent  claude-code --project-strategy repo-root --apply || \
    log "warning: install-hooks failed (server may still be starting)"
fi

# --- devbox-doctor -----------------------------------------------------------
# Installed from the mounted repo so the VM always has the version that
# matches this provision.sh. On subsequent runs we just re-copy it.
if [ -f /mnt/dev/devbox/devbox-doctor ]; then
  install -m 0755 /mnt/dev/devbox/devbox-doctor "$HOME/.local/bin/devbox-doctor"
else
  log "warning: /mnt/dev/devbox/devbox-doctor not found — is DEV_ROOT correct?"
fi

# --- Sentinel ----------------------------------------------------------------
# up.sh reads this to know provisioning finished, then reboots the VM from
# the OUTSIDE so `sudo usermod -aG docker $USER` (above) takes effect in
# every future shell. Rebooting from inside cloud-init confuses Lima's
# start-up state machine and fails the initial `limactl start`.
touch "$HOME/.provision-done"
log "provision complete. up.sh will restart the VM to activate docker group."
