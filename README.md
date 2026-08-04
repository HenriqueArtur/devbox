# devbox

Reproducible Linux dev VM for macOS, powered by [Lima](https://lima-vm.io).

One YAML template + one `.env` per profile + a provision script gives you an
Ubuntu VM with Rust, Node, Neovim (via [nvim-config](https://github.com/HenriqueArtur/nvim-config)),
dotfiles (zsh + powerlevel10k), `gh`, `gcloud`, Docker, and Claude Code.

**Profiles** let one Mac host multiple independent VMs — e.g. one for personal
projects, one for work — each with its own `~/Documents/dev/<subdir>` mount
and its own agent logins.

Claude Code's sessions, history and login live on the Mac (`STATE_ROOT`), not on
the VM disk, so `./nuke.sh && ./up.sh` gets you a clean machine without losing
`claude --resume`.

Reproduce the exact same environment on another Mac by cloning this repo,
writing a local `devbox.env`, and running `./up.sh`. Recreate from scratch by
running `./nuke.sh && ./up.sh`.

## Prerequisites (host Mac)

```bash
brew install lima gettext
```

`gettext` is for `envsubst`, which renders the template.

You also need the source directories that will be mounted into the VM. At
minimum:

- `DEV_ROOT` — where this profile's project code lives on the Mac.
- `PROVISION_ROOT` — where the `devbox` repo itself lives (usually
  `~/Documents/dev/devbox`).
- `STATE_ROOT` — per-profile state that outlives the VM disk. `up.sh` creates
  this one for you.

Create `DEV_ROOT` before the first `./up.sh`.

## Profiles

`./up.sh` (no argument) uses the **default** profile — env file `devbox.env`,
Lima VM named per your `VM_NAME`, YAML rendered to `devbox.yaml`.

`./up.sh <profile>` uses a named profile — env file `devbox.<profile>.env`,
YAML rendered to `devbox.<profile>.yaml`. Two profiles must have different
`VM_NAME` values so Lima can distinguish them.

Every script (`up.sh`, `down.sh`, `nuke.sh`, `doctor.sh`) accepts the same
optional profile argument.

The two profiles in use today:

| Profile           | VM       | `DEV_ROOT`                 | Extras          |
| ----------------- | -------- | -------------------------- | --------------- |
| default (personal)| `devbox` | `~/Documents/dev/personal` | `flyctl`        |
| `sunne` (work)    | `sunne`  | `~/Documents/dev/work`     | —               |

Anything a profile does not opt into is simply absent from that VM — the work
VM has no `flyctl`, so an agent there cannot touch personal Fly.io apps.

## First run

```bash
cd ~/Documents/dev/devbox
cp devbox.env.example devbox.env
$EDITOR devbox.env         # adjust paths, CPUs, memory
./up.sh                    # renders devbox.yaml, boots the VM, runs provision
./doctor.sh                # verify everything came up green
```

Provisioning downloads Rust, Node, Neovim, Docker, and Claude Code. First
run takes 15–30 minutes depending on your connection.

## Adding a second profile

```bash
cp devbox.env.example devbox.sunne.env
$EDITOR devbox.sunne.env   # set VM_NAME=sunne and DEV_ROOT to a distinct subdir
./up.sh sunne
./doctor.sh sunne
```

The two VMs run in parallel. Each has its own `gh` / `gcloud` login, its own
Claude Code state, and only sees the files under its own `DEV_ROOT`.

## Daily use

```bash
./up.sh                    # start default profile (idempotent)
./up.sh sunne              # start "sunne" profile
limactl shell devbox       # enter default
limactl shell sunne        # enter "sunne"
./down.sh                  # stop default but keep state
./down.sh sunne            # stop "sunne" but keep state
```

Inside any VM your code is at `/mnt/dev`, or the convenience symlink
`~/projects`.

## Recreate from scratch

```bash
./nuke.sh                  # confirmation prompt; deletes default VM's disk
./nuke.sh sunne            # or a specific profile
./up.sh                    # re-provisions from the template
```

Your project code and dotfiles are safe — they live on the Mac. So does Claude
Code's state (see below). What is destroyed: installed packages, cargo cache,
`gh` / `gcloud` / `fly` logins, and shell history.

## Persistent state (`/mnt/state`)

`STATE_ROOT` on the Mac — `~/.devbox/state/<VM_NAME>` by default — is mounted at
`/mnt/state` and is the one place a VM can write to that `nuke.sh` never
touches. `up.sh` creates it.

Claude Code is pointed at it via `CLAUDE_CONFIG_DIR=/mnt/state/claude`
(exported in `/etc/environment` and `/etc/profile.d/devbox-claude.sh`), which
relocates the *whole* config dir: session transcripts, `projects/`, `sessions/`,
`history.jsonl`, `settings.json`, `.claude.json` and the OAuth login. So after
`./nuke.sh && ./up.sh`:

```bash
limactl shell devbox
cd ~/projects/some-repo
claude --resume        # every past session still listed; no re-login
```

Session transcripts are keyed by absolute working directory, and code always
sits at the same guest path (`/mnt/dev/<repo>`), so the keys survive recreation
too. Each profile has its own `STATE_ROOT`, so the two VMs never share history
or credentials.

To start Claude Code genuinely fresh, delete the directory on the Mac:

```bash
rm -rf ~/.devbox/state/devbox/claude
```

Other tools' logins are still VM-local by choice — `gh`, `gcloud` and `fly` are
cheap to redo and are exactly the credentials worth re-confirming after a
rebuild. To persist one anyway, add a symlink into `/mnt/state` in
`provision.sh` (e.g. `~/.config/gh` → `/mnt/state/gh`).

## Files

```
devbox/
├── devbox.env.example       # committed: variable list with defaults
├── devbox.env               # local: default-profile values (gitignored)
├── devbox.<profile>.env     # local: extra profiles (gitignored)
├── devbox.yaml.tmpl         # committed: Lima template with ${VAR} placeholders
├── devbox.yaml              # generated: default profile (gitignored)
├── devbox.<profile>.yaml    # generated: per-profile (gitignored)
├── provision.sh             # committed: runs inside the VM on first boot
├── devbox-doctor            # committed: script installed into every VM
├── _lib.sh                  # committed: profile resolution helpers
├── up.sh / down.sh / nuke.sh
└── doctor.sh
```

## Two Macs, same environment

Everything you need is in this repo. On a new Mac:

```bash
brew install lima gettext
git clone <this-repo> ~/Documents/dev/devbox
cd ~/Documents/dev/devbox
cp devbox.env.example devbox.env
$EDITOR devbox.env         # DEV_ROOT reflects where things live on this Mac
./up.sh
```

The template picks up your machine-local paths from `devbox.env`; the rest
of the environment (Ubuntu version, Rust version, installed tools,
dotfiles, nvim config) is identical.

Your project code is synced separately (git per repo) — the VM never syncs.

## Reprovisioning after a template change

Two options:

- **Soft**: SSH into the VM and re-run `bash /mnt/tooling/provision.sh`.
  Fast, keeps state.
- **Hard**: `./nuke.sh && ./up.sh`. Guarantees the template is complete.
  Slow, forces state to be recoverable from outside the VM (which it should
  be — dotfiles are cloned from GitHub, project code lives on the Mac).

## Agents and the sandbox boundary

There is no in-VM jail: the VM *is* the boundary. An agent running here has your
`gh`, `gcloud` and (personal profile) `fly` credentials, plus the Mac's SSH agent
via Lima's forwarding, so `git push` and `gh pr create` just work.

What contains it:

- Only this profile's `DEV_ROOT` is mounted. The work VM cannot see personal
  code and vice versa; neither can see the rest of the Mac.
- Per-profile tool opt-ins. No `flyctl` in the work VM means no Fly.io deploys
  from it, whatever the agent decides to try.
- `bubblewrap` is installed and unprivileged user namespaces are enabled, so
  Claude Code's own Bash sandbox works if you turn it on.

Treat "recreate the VM" as the cleanup step: `./nuke.sh && ./up.sh` gives you a
fresh machine in ~20 minutes and, because `STATE_ROOT` is separate, keeps your
Claude Code history.

## flyctl (personal profile only)

`INSTALL_FLYCTL="1"` in a profile's `.env` installs `flyctl` + `fly` into
`~/.fly/bin` and symlinks both into `~/.local/bin`. `FLYCTL_VERSION` pins a
release or takes `latest`.

```bash
fly auth login         # once per VM; auth is VM-local, redo after nuke.sh
fly deploy
```

The `sunne` profile leaves it at `0` on purpose.

## Prompt (powerlevel10k)

The zsh prompt comes from the [dotfiles](https://github.com/HenriqueArtur/dotfiles)
repo: `common/.p10k.zsh` is shared with macOS, and `linux/.zshrc` sources the
theme from `~/repos/powerlevel10k`, which `provision.sh` clones. Icons need a
Nerd Font in the Mac's terminal — that is a host-side setting, since
`limactl shell` renders in your terminal.

Because dotfiles are cloned from GitHub (never mounted), a change to them
reaches a VM only after you push it. `provision.sh` runs `git pull --ff-only` on
re-provision, so a soft reprovision picks it up.

## Notes

- `vmType: vz` uses macOS Virtualization.framework — fast on Apple Silicon.
  Intel Macs may need `vmType: qemu` (edit the template).
- `mountType: virtiofs` is the fastest mount driver but requires `vz`. If you
  switch to qemu, change to `mountType: reverse-sshfs` or `9p`.
- SSH agent forwarding is on at the Lima level, so `git push` inside the VM
  uses the Mac's key without ever copying it in.
- `/mnt/state` is a virtiofs mount, and Claude Code writes its whole config dir
  there. If that ever misbehaves, unset `CLAUDE_CONFIG_DIR` in
  `/etc/profile.d/devbox-claude.sh` to fall back to VM-local state — you lose
  persistence, not the tool.
