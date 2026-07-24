#!/usr/bin/env bash
# provision.sh — runs inside the Lima VM on first boot (as the `lima` user).
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

# --- Rust (pinned) -----------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
  log "installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
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
  curl https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"
mise use -g "node@${NODE_VERSION}"

# --- Neovim (latest stable from apt is usually behind; use unstable PPA-free path) ---
# 24.04 ships nvim 0.9.5 which is too old for LazyVim.
# Grab the official appimage build.
if ! command -v nvim >/dev/null 2>&1 || \
   [ "$(nvim --version | head -1 | awk '{print $2}' | tr -d 'v')" \< "0.10.0" ]; then
  log "installing neovim (appimage)"
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  nvim_url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage" ;;
    aarch64) nvim_url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.appimage" ;;
    *) log "unsupported arch for nvim: $arch"; exit 1 ;;
  esac
  sudo curl -fsSL -o /usr/local/bin/nvim "$nvim_url"
  sudo chmod +x /usr/local/bin/nvim
fi

# --- lazygit (pinned; nvim-config expects the same version everywhere) ------
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
  curl -fsSL -o "$tmp/lg.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${lg_arch}.tar.gz"
  tar -xf "$tmp/lg.tar.gz" -C "$tmp" lazygit
  mkdir -p "$HOME/.local/bin"
  install "$tmp/lazygit" "$HOME/.local/bin/lazygit"
  rm -rf "$tmp"
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
# nvim-config's own installer handles apt deps + symlink.
# Since we already installed nvim/ripgrep/fd/git, this mostly just symlinks.
( cd "$NVIM_CONFIG_DIR" && ./install.sh || true )
# nvim-config's installer runs apt on Linux and expects a package manager it
# knows; we already installed the deps above, so tolerate its failure here.

# --- ai-jail (from cargo) ----------------------------------------------------
if ! command -v ai-jail >/dev/null 2>&1; then
  log "installing ai-jail"
  sudo apt-get install -y bubblewrap
  cargo install ai-jail
fi

# --- ai-memory (from cargo) --------------------------------------------------
if ! command -v ai-memory >/dev/null 2>&1; then
  log "installing ai-memory"
  cargo install ai-memory
fi

# --- Claude Code CLI ---------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  log "installing claude code cli"
  # Uses npm from the mise-managed node.
  npm install -g @anthropic-ai/claude-code
fi

log "done. open a new shell (or 'zsh') to pick up PATH changes."
