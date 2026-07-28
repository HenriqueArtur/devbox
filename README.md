# devbox

Reproducible Linux dev VM for macOS, powered by [Lima](https://lima-vm.io).

One YAML template + one `.env` per profile + a provision script gives you an
Ubuntu VM with Rust, Node, Neovim (via [nvim-config](https://github.com/HenriqueArtur/nvim-config)),
dotfiles, `gh`, Docker, `ai-jail`, and Claude Code.

**Profiles** let one Mac host multiple independent VMs — e.g. one for personal
projects, one for work — each with its own `~/Documents/dev/<subdir>` mount
and its own agent logins.

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

Create `DEV_ROOT` before the first `./up.sh`.

## Profiles

`./up.sh` (no argument) uses the **default** profile — env file `devbox.env`,
Lima VM named per your `VM_NAME`, YAML rendered to `devbox.yaml`.

`./up.sh <profile>` uses a named profile — env file `devbox.<profile>.env`,
YAML rendered to `devbox.<profile>.yaml`. Two profiles must have different
`VM_NAME` values so Lima can distinguish them.

Every script (`up.sh`, `down.sh`, `nuke.sh`, `doctor.sh`) accepts the same
optional profile argument.

## First run

```bash
cd ~/Documents/dev/devbox
cp devbox.env.example devbox.env
$EDITOR devbox.env         # adjust paths, CPUs, memory
./up.sh                    # renders devbox.yaml, boots the VM, runs provision
./doctor.sh                # verify everything came up green
```

Provisioning downloads Rust, Node, Neovim, Docker, and the AI tools. First
run takes 15–30 minutes depending on your connection.

## Adding a second profile

```bash
cp devbox.env.example devbox.sunne.env
$EDITOR devbox.sunne.env   # set VM_NAME=sunne and DEV_ROOT to a distinct subdir
./up.sh sunne
./doctor.sh sunne
```

The two VMs run in parallel. Each has its own Claude Code / gh login and only
sees the files under its own `DEV_ROOT`.

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

Your project code and dotfiles are safe — they live on the Mac. Only the VM's
internal state (installed packages, cargo cache, Claude Code login, gh token,
shell history) is destroyed.

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

## ai-jail with git + gh

`provision.sh` writes `~/.ai-jail` inside the VM that forwards the SSH agent
socket and exposes `~/.config/gh`. That means, inside any project:

```bash
ai-jail claude --dangerously-skip-permissions
# and inside the jail:
git push               # uses the Mac's SSH key via forwarded agent
gh pr create           # uses your gh login token
```

The `~/.ai-jail` file is created on first provision and never overwritten
after that. Edit it freely — `nuke.sh` + `up.sh` regenerates it.

## gcloud is opt-in per session

`gcloud` is installed and can be authenticated (`gcloud auth login`) but is
NOT exposed inside `ai-jail` by default. Unlike `gh`, `gcloud` can create and
delete paid infrastructure irreversibly, so every agent session opts in
explicitly:

```bash
ai-jail --rw-map ~/.config/gcloud claude --dangerously-skip-permissions
```

Or, for a single project that always needs it, drop a `.ai-jail` file at
the repo root:

```toml
rw_maps = ["~/.config/gcloud"]
```

## Notes

- `vmType: vz` uses macOS Virtualization.framework — fast on Apple Silicon.
  Intel Macs may need `vmType: qemu` (edit the template).
- `mountType: virtiofs` is the fastest mount driver but requires `vz`. If you
  switch to qemu, change to `mountType: reverse-sshfs` or `9p`.
- SSH agent forwarding is on at the Lima level, so `git push` inside the VM
  (outside `ai-jail`) uses the Mac's key without copying it in. Inside
  `ai-jail`, the same behaviour requires the `~/.ai-jail` passthrough above.
