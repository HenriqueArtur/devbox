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
# Lima's virtual user defaults to /bin/bash. Our dotfiles target zsh, and
# `mise activate` in .zshrc is what puts npm-installed binaries (claude,
# gemini, etc) on PATH.
CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "/usr/bin/zsh" ]; then
  log "setting default shell to zsh for $USER"
  sudo chsh -s /usr/bin/zsh "$USER"
fi

# --- Convenience symlinks to Mac-side mounts --------------------------------
# ~/projects → /mnt/dev  (your code, scoped to this profile's DEV_ROOT)
ln -sfn /mnt/dev "$HOME/projects"

# --- Enable unprivileged user namespaces (required by ai-jail's bwrap) ------
# Ubuntu 24.04's default AppArmor policy denies user-namespace creation for
# unprivileged users. Every tool that uses rootless user namespaces breaks:
# ai-jail (bwrap), rootless podman, flatpak, distrobox. We are inside a
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

# --- Docker Engine (kept even without ai-memory: useful for local Postgres,
# Redis, Playwright browsers, etc). ------------------------------------------
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

# --- GitHub CLI (gh) --------------------------------------------------------
# From the official GitHub apt repository, not the distro package which lags.
if ! command -v gh >/dev/null 2>&1; then
  log "installing gh (GitHub CLI)"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y gh
fi

# --- Google Cloud CLI (gcloud) ----------------------------------------------
# Full SDK matches the Mac install (`brew install --cask gcloud-cli`) — same
# gcloud + bq + gsutil + bundled Python. GKE-auth-plugin and kubectl are NOT
# installed: add them later if you start using GKE.
#
# Ai-jail does NOT expose ~/.config/gcloud by default (unlike ~/.config/gh).
# Rationale: gcloud can create/delete paid infra irreversibly, so each
# agent session opts in explicitly with `ai-jail --rw-map ~/.config/gcloud`.
if ! command -v gcloud >/dev/null 2>&1; then
  log "installing google-cloud-cli"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
    https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y google-cloud-cli
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
# nvim-config's installer re-runs apt for a set of deps we already installed.
# Its non-zero exit is not fatal — the symlink step (what we need) still runs.
( cd "$NVIM_CONFIG_DIR" && ./install.sh || true )

# --- ai-jail (from cargo) ----------------------------------------------------
if ! command -v ai-jail >/dev/null 2>&1; then
  log "installing ai-jail"
  sudo apt-get install -y bubblewrap
  cargo install ai-jail
fi

# --- Global ai-jail config: forward SSH agent + gh auth ---------------------
# ~/.ai-jail applies to every project inside this VM (per-project .ai-jail
# still overrides it). We expose:
#   - SSH_AUTH_SOCK from the Mac (Lima already forwards it into the VM) so
#     `git push` works via the Mac's identity from inside the jail.
#   - ~/.config/gh so gh auth persists across ai-jail sessions.
# See ai-jail's README "Security notes" — this widens the sandbox surface;
# accept it explicitly because we want git/gh usable during agent sessions.
if [ ! -f "$HOME/.ai-jail" ]; then
  log "writing global ~/.ai-jail (SSH agent + gh auth passthrough)"
  # Compute the current SSH agent socket dir on the Mac-forwarded agent,
  # so we can rw-map its parent (ai-jail does not expand env vars inside
  # rw_maps — it treats them as literal paths).
  ssh_sock_dir=""
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "$SSH_AUTH_SOCK" ]; then
    ssh_sock_dir="$(dirname "$SSH_AUTH_SOCK")"
  fi
  cat > "$HOME/.ai-jail" <<TOML
# Global ai-jail config. Applies to every invocation of \`ai-jail\` in this
# user account; per-project \`.ai-jail\` in a repo root takes precedence.
#
# Managed by devbox provision.sh. Edit freely, but note that a \`nuke.sh\` +
# \`up.sh\` will overwrite this file.

# Forward SSH_AUTH_SOCK env into the jail so \`git push\` sees an agent.
env_passthrough = ["SSH_AUTH_SOCK"]
$( [ -n "$ssh_sock_dir" ] && echo "
# Expose the agent socket's directory so the socket path is reachable
# inside the jail. Path resolved at provision time — ai-jail does not
# expand \\\$SSH_AUTH_SOCK inside rw_maps.
rw_maps = [\"$ssh_sock_dir\"]" )

# Persist gh's auth token across sessions.
[commands.claude]
rw_maps = ["~/.config/gh"]

[commands.gh]
rw_maps = ["~/.config/gh"]
TOML
fi

# --- Claude Code CLI ---------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  log "installing claude code cli"
  npm install -g @anthropic-ai/claude-code
fi

# --- devbox-doctor -----------------------------------------------------------
# Installed from the tooling mount so the VM always has the version that
# matches this provision.sh. On subsequent runs we just re-copy it.
if [ -f /mnt/tooling/devbox-doctor ]; then
  install -m 0755 /mnt/tooling/devbox-doctor "$HOME/.local/bin/devbox-doctor"
else
  log "warning: /mnt/tooling/devbox-doctor not found — is PROVISION_ROOT correct?"
fi

# --- Sentinel ----------------------------------------------------------------
# up.sh reads this to know provisioning finished, then reboots the VM from
# the OUTSIDE so `sudo usermod -aG docker $USER` (above) takes effect in
# every future shell. Rebooting from inside cloud-init confuses Lima's
# start-up state machine and fails the initial `limactl start`.
touch "$HOME/.provision-done"
log "provision complete. up.sh will restart the VM to activate docker group."
