# limactl-recover.zsh — host-side (macOS) zsh helper. Source it from ~/.zshrc:
#
#   source ~/Documents/dev/devbox/limactl-recover.zsh
#
# Wraps `limactl` so `limactl shell <vm>` and `limactl start <vm>` recover a VM
# left Broken ("vz driver is running but host agent is not") by an unclean macOS
# shutdown/sleep — lima-vm/lima#5087. Same recovery as up.sh: force-stop to
# clear the orphaned VZ pid, then start. The disk is untouched.
#
# Every other subcommand, and every VM that is not Broken, goes straight to the
# real limactl.

limactl() {
  if [[ $1 == shell || $1 == start ]]; then
    # First positional argument after the subcommand is the instance. Skip
    # flags; the ones listed take a separate value (`--workdir /x`).
    local vm= arg skip=0
    for arg in "${@:2}"; do
      if (( skip )); then skip=0; continue; fi
      case $arg in
        --) break ;;
        --workdir|--shell|--log-level|--name|--set) skip=1 ;;
        -*) ;;
        *) vm=$arg; break ;;
      esac
    done
    vm=${vm:-default}

    if [[ "$(command limactl list --format '{{.Status}}' "$vm" 2>/dev/null)" == Broken ]]; then
      print -u2 "[limactl] '$vm' is Broken (Lima #5087: VZ orphaned by macOS shutdown/sleep); recovering"
      # After a reboot the pid in vz.pid usually belongs to some unrelated
      # process, and `stop --force` would kill it. Only force-stop a real
      # Lima process; otherwise just drop the stale pidfile.
      local dir="$(command limactl list --format '{{.Dir}}' "$vm")"
      local pid=
      [[ -r $dir/vz.pid ]] && pid="$(<"$dir/vz.pid")"
      if [[ -n $pid ]] && ps -o command= -p "$pid" 2>/dev/null | grep -q "limactl.* $vm\$"; then
        command limactl stop --force "$vm" || return
      else
        rm -f "$dir/vz.pid"
      fi
      if [[ $1 == shell ]]; then
        command limactl start "$vm" || return
      fi
    fi
  fi
  command limactl "$@"
}
