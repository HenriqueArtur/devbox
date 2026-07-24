# devbox

Reproducible Linux dev VM for macOS, powered by [Lima](https://lima-vm.io).

One YAML template + one `.env` per machine + a provision script gives you an
Ubuntu VM with Rust, Node, Neovim (via [nvim-config](https://github.com/HenriqueArtur/nvim-config)),
dotfiles, and the AI tooling stack (`ai-jail`, `ai-memory`, Claude Code).

Reproduce the exact same environment on another Mac by cloning this repo,
writing a local `devbox.env`, and running `./up.sh`. Recreate from scratch by
running `./nuke.sh && ./up.sh`.

## Prerequisites (host Mac)

```bash
brew install lima gettext
```

`gettext` is for `envsubst`, which renders the template.

You also need the source directories that will be mounted into the VM:

- `DEV_ROOT` — where your project code lives (this repo lives here too).
- `WIKI_ROOT` — where `ai-memory`'s wiki lives (git repo synced across Macs).

Create them before the first `./up.sh`.

## First run

```bash
cd ~/Documents/dev/devbox
cp devbox.env.example devbox.env
$EDITOR devbox.env         # adjust paths, CPUs, memory
./up.sh                    # renders devbox.yaml, boots the VM, runs provision
```

Provisioning downloads Rust, Node, Neovim, and the AI tools. First run takes
15–30 minutes depending on your connection.

## Daily use

```bash
./up.sh                    # start (idempotent — no-op if already running)
limactl shell devbox       # enter the VM
./down.sh                  # stop but keep state
```

Inside the VM your code is at `/mnt/dev`, the ai-memory wiki at `/mnt/wiki`.

## Recreate from scratch

```bash
./nuke.sh                  # confirmation prompt; deletes the VM's disk
./up.sh                    # re-provisions from the template
```

Your projects and wiki are safe — only the VM's internal state (installed
packages, cargo cache, Claude Code login, shell history) is destroyed.

## Files

```
devbox/
├── devbox.env.example     # committed: variable list with defaults
├── devbox.env             # local: your machine's values (gitignored)
├── devbox.yaml.tmpl       # committed: Lima template with ${VAR} placeholders
├── devbox.yaml            # generated: rendered template (gitignored)
├── provision.sh           # committed: runs inside the VM on first boot
├── up.sh                  # render + start
├── down.sh                # stop
└── nuke.sh                # delete
```

## Two Macs, same environment

Everything you need is in this repo. On a new Mac:

```bash
brew install lima gettext
git clone <this-repo> ~/Documents/dev/devbox
cd ~/Documents/dev/devbox
cp devbox.env.example devbox.env
$EDITOR devbox.env         # DEV_ROOT and WIKI_ROOT reflect where things live on this Mac
./up.sh
```

The template picks up your machine-local paths from `devbox.env`; the rest of
the environment (Ubuntu version, Rust version, installed tools, dotfiles,
nvim config) is identical.

The ai-memory wiki and your project code are synced separately (git,
Syncthing, whatever) — the VM never syncs.

## Reprovisioning after a template change

Two options:

- **Soft**: SSH into the VM and re-run `bash /mnt/dev/devbox/provision.sh`.
  Fast, keeps state.
- **Hard**: `./nuke.sh && ./up.sh`. Guarantees the template is complete.
  Slow, forces state to be recoverable from outside the VM (which it should
  be — see "State vs environment" in the design notes).

## Notes

- `vmType: vz` uses macOS Virtualization.framework — fast on Apple Silicon.
  Intel Macs may need `vmType: qemu` (edit the template).
- `mountType: virtiofs` is the fastest mount driver but requires `vz`. If you
  switch to qemu, change to `mountType: reverse-sshfs` or `9p`.
- SSH agent forwarding is on, so `git push` inside the VM uses the Mac's key.
