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

# Optional, per-profile. Empty (profile did not set it) means "off"/default.
: "${INSTALL_FLYCTL:=0}"
: "${FLYCTL_VERSION:=latest}"

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

# --- Enable unprivileged user namespaces (bubblewrap sandboxes) -------------
# Ubuntu 24.04's default AppArmor policy denies user-namespace creation for
# unprivileged users. Every tool that uses rootless user namespaces breaks:
# bwrap (Claude Code's own Bash sandbox), rootless podman, flatpak, distrobox.
# We are inside a dedicated Lima VM — the extra isolation is redundant with
# the VM boundary.
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
# Note that with ai-jail gone, an agent running in this VM reaches gcloud (and
# gh, and flyctl) with your full credentials. The VM boundary is the sandbox
# now: what protects the Mac is that only this profile's DEV_ROOT is mounted.
# `gcloud auth login` is still manual, per VM.
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

# --- flyctl (opt-in per profile: INSTALL_FLYCTL=1) --------------------------
# Only the profiles that actually deploy to Fly.io get it — see the
# INSTALL_FLYCTL note in devbox.env.example.
#
# The installer drops both `flyctl` and `fly` into ~/.fly/bin, which is not on
# PATH (PATH comes from the dotfiles' .zshenv and we do not want devbox
# appending to it), so we symlink both into ~/.local/bin, which is.
#
# Auth (`fly auth login`) lands in ~/.fly/config.yml and is VM-local: it does
# NOT survive nuke.sh. See README "Persistent state" if you want it moved to
# the state mount.
if [ "$INSTALL_FLYCTL" = "1" ]; then
  flyctl_installed=""
  if [ -x "$HOME/.fly/bin/flyctl" ]; then
    flyctl_installed="$("$HOME/.fly/bin/flyctl" version 2>/dev/null \
      | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || true)"
  fi
  want="$(echo "$FLYCTL_VERSION" | tr -d 'v')"
  # "latest" never matches a version string, so it re-runs the installer on
  # every provision — that is the point of not pinning.
  if [ "$flyctl_installed" != "$want" ]; then
    log "installing flyctl ${FLYCTL_VERSION}"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
      https://fly.io/install.sh | sh -s -- --non-interactive "$FLYCTL_VERSION"
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$HOME/.fly/bin/flyctl" "$HOME/.local/bin/flyctl"
  ln -sfn "$HOME/.fly/bin/fly"    "$HOME/.local/bin/fly"
else
  log "INSTALL_FLYCTL != 1 — skipping flyctl for this profile"
fi

# --- dotfiles ----------------------------------------------------------------
DOTFILES_DIR="$REPOS_DIR/dotfiles"
if [ ! -d "$DOTFILES_DIR" ]; then
  log "cloning dotfiles"
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
else
  # Re-provisioning an existing VM should pick up dotfiles pushed since the
  # clone. --ff-only so a dirty or diverged tree is left alone instead of
  # being merged behind your back.
  git -C "$DOTFILES_DIR" pull --ff-only || \
    log "warning: could not fast-forward dotfiles — resolve it inside the VM"
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

# --- powerlevel10k -----------------------------------------------------------
# The prompt config itself (~/.p10k.zsh) is a dotfile shared with the Mac —
# it lives in dotfiles/common/ and was symlinked by the installer above. This
# only installs the theme the config drives; dotfiles/linux/.zshrc sources it
# from here and falls back to a plain prompt when it is missing.
P10K_DIR="$REPOS_DIR/powerlevel10k"
if [ ! -d "$P10K_DIR" ]; then
  log "cloning powerlevel10k"
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
else
  git -C "$P10K_DIR" pull --ff-only || true
fi
# gitstatusd is a prebuilt binary p10k fetches on first prompt. Doing it here
# keeps the first interactive shell from stalling; failure is not fatal because
# p10k falls back to plain `git` calls.
if [ -x "$P10K_DIR/gitstatus/install" ]; then
  "$P10K_DIR/gitstatus/install" -f >/dev/null 2>&1 || \
    log "warning: gitstatusd prefetch failed — p10k will fall back to git"
fi

# --- Claude Code state on the Mac (survives nuke.sh) -------------------------
# Everything Claude Code keeps in its config dir — resumable session
# transcripts (projects/, sessions/), the OAuth login, history, settings — is
# redirected to /mnt/state/claude, a Mac-side directory (STATE_ROOT). nuke.sh
# only deletes the VM disk, so `claude --resume` still lists every past session
# in a freshly recreated VM.
#
# Transcripts are keyed by absolute cwd and the code is always at the same
# guest path (/mnt/dev/<repo>), so those keys stay stable across recreation too.
CLAUDE_STATE_DIR="/mnt/state/claude"
if [ ! -d /mnt/state ]; then
  log "warning: /mnt/state not mounted — STATE_ROOT missing from this profile's"
  log "warning: .env file. Claude state stays VM-local and nuke.sh will lose it."
else
  mkdir -p "$CLAUDE_STATE_DIR"
  # Non-fatal: up.sh already chmods it Mac-side, and a chmod that virtiofs
  # refuses must not take the whole provision down with it.
  chmod 700 "$CLAUDE_STATE_DIR" || true

  # One-time migration: a VM provisioned before this change keeps its state in
  # ~/.claude + ~/.claude.json. Move it onto the mount instead of leaving it on
  # a disk that nuke.sh throws away.
  if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ] && \
     [ -z "$(ls -A "$CLAUDE_STATE_DIR" 2>/dev/null)" ]; then
    log "migrating existing ~/.claude into $CLAUDE_STATE_DIR"
    cp -a "$HOME/.claude/." "$CLAUDE_STATE_DIR/"
    [ -f "$HOME/.claude.json" ] && cp -a "$HOME/.claude.json" "$CLAUDE_STATE_DIR/.claude.json"
    mv "$HOME/.claude" "$HOME/.claude.pre-devbox-state"
  fi

  # CLAUDE_CONFIG_DIR relocates the entire config dir — .claude.json and the
  # stored OAuth credentials included. /etc/environment is read by PAM, so
  # every `limactl shell` and ssh session sees it whatever the shell is.
  if ! grep -q '^CLAUDE_CONFIG_DIR=' /etc/environment 2>/dev/null; then
    log "setting CLAUDE_CONFIG_DIR=$CLAUDE_STATE_DIR in /etc/environment"
    echo "CLAUDE_CONFIG_DIR=$CLAUDE_STATE_DIR" | sudo tee -a /etc/environment >/dev/null
  fi
  # Belt and braces: PAM does not apply to `limactl shell <vm> -- cmd` style
  # non-login invocations in every Lima version, and zsh ignores
  # /etc/profile.d unless /etc/zsh/zprofile sources /etc/profile (Ubuntu's
  # does). Cheap enough to set both.
  sudo tee /etc/profile.d/devbox-claude.sh >/dev/null <<EOF
# Managed by devbox provision.sh — do not edit, see /mnt/tooling/provision.sh.
export CLAUDE_CONFIG_DIR="$CLAUDE_STATE_DIR"
EOF
  export CLAUDE_CONFIG_DIR="$CLAUDE_STATE_DIR"

  # Fallback: if a shell ever loses the env var, ~/.claude still resolves to
  # the persisted dir instead of quietly starting a fresh VM-local one.
  if [ ! -e "$HOME/.claude" ] || [ -L "$HOME/.claude" ]; then
    ln -sfn "$CLAUDE_STATE_DIR" "$HOME/.claude"
  fi
fi

# --- Claude Code CLI (native binary, deliberately NOT the npm package) -------
# The npm global package has misbehaved for us before. The native installer
# checks the release manifest's SHA256, puts a self-contained binary under
# ~/.local/share/claude/versions/ with a launcher at ~/.local/bin/claude, and
# updates itself from then on — which is why nothing is pinned here.
#
# ~/.local/bin is already first on PATH via the dotfiles' .zshenv, so the
# installer has no reason to touch any shell rc file (and must not: ~/.zshrc is
# a symlink into the dotfiles clone).
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ "$CLAUDE_BIN" != "$HOME/.local/bin/claude" ]; then
  # A VM provisioned by an earlier devbox may still carry the npm install.
  # Remove it first, otherwise its mise shim keeps shadowing the native
  # launcher on PATH and this block re-runs on every provision.
  if command -v npm >/dev/null 2>&1 && \
     npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
    log "removing npm-installed claude code in favour of the native binary"
    npm uninstall -g @anthropic-ai/claude-code || true
    mise reshim || true
  fi
  log "installing claude code (native installer)"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 300 \
    https://claude.ai/install.sh | bash
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
