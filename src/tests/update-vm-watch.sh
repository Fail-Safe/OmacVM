#!/bin/bash
# OmacVM.app's Update VM (app/scripts/update-vm.sh) never waits forever: a
# disk that fails (btrfs/ext4 errors or a read-only file system on the VM's
# console or in the apply) or an update past its time stops the VM and says
# why, with the next step. 2026-10-09: a VM copied while it ran came up on a
# MacBook Air with "BTRFS error ... bad tree block start", went read-only,
# and Update VM hung. A newer memory-optimized kernel is asked first (ASK
# kernel on stdout, the answer on stdin) and a build gets its time
# (2026-10-17: a weekly ALARM kernel build started by itself in Update VM).
# A VM that knows only another Mac's SSH key: wait_ssh stops at the first
# "Permission denied" (it waited 5 minutes, then said the VM did not come
# up: M-kk, 2026-10-19), the app is asked to add the key through the guest
# agent (FIX ssh-key, the answer on stdin), and without it the VM goes off by
# ACPI, not QMP quit.
# A stand-in QEMU, ssh, curl, nc and apply in a fixture app; no VM.
#   src/tests/update-vm-watch.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
cleanup() {
  [[ -f $T/qemu.pid ]] && kill "$(cat "$T/qemu.pid")" 2>/dev/null
  rm -f "$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(printf '%s' "$T/VMs/Copied" | shasum | cut -c1-8)".*   # vm_load's pid file
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# disk_error on its own.
eval "$(sed -n -e '/^printable()/,/^}/p' -e '/^disk_error()/,/^}/p' "$R/app/scripts/vm-common.sh")"
printf '[    1.2] nvme nvme0: 4/0/0 default/read/poll queues\n[  OK  ] Reached target Graphical Interface.\nRemounting '"'"'/'"'"' read-only with options compress=zstd:1.\n' > "$T/clean.log"
printf '[   3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0\n[   3.2] BTRFS: error (device nvme0n1p2) in btrfs_run_delayed_refs\n' > "$T/btrfs.log"
printf 'touch: cannot touch '"'"'/usr/local/share/omacvm/x'"'"': Read-only file system\n' > "$T/ro.log"
printf '[  12.0] EXT4-fs error (device vda1): ext4_lookup:1855: inode #2: comm ls: deleted inode referenced\n' > "$T/ext4.log"
expect "a clean boot and shutdown: no disk error" "" "$(disk_error "$T/clean.log")"
expect "btrfs errors" "[   3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0" "$(disk_error "$T/btrfs.log")"
expect "a read-only file system in the apply" "touch: cannot touch '/usr/local/share/omacvm/x': Read-only file system" "$(disk_error "$T/clean.log" "$T/ro.log")"
expect "ext4 errors" "yes" "$(disk_error "$T/ext4.log" >/dev/null && echo yes)"
expect "no file: no error" "" "$(disk_error "$T/none.log")"

# A fixture app: the real scripts and src/, a stand-in QEMU, ssh and apply.
A=$T/app; mkdir -p "$A/scripts" "$A/runtime/bin" "$A/firmware" "$A/omacvm" "$T/bin"
cp "$R"/app/scripts/*.sh "$A/scripts/"
ln -s "$R/src" "$A/omacvm/src"
: > "$A/firmware/edk2-aarch64-code.fd"
cat > "$A/runtime/bin/OmacVM" <<'QEMU'
#!/bin/bash
# Stand-in QEMU: writes the console its mode asks for, runs until killed.
echo $$ > "$FAKE_DIR/qemu.pid"
while [[ $# -gt 0 ]]; do
  [[ $1 == -serial ]] && console=${2#file:}
  # The guest agent's port: its socket path, as QEMU would make it.
  if [[ $1 == -chardev && $2 == socket,id=qga0,* ]]; then p=${2#*path=}; p=${p%%,server=*}; : > "$p"; echo "$p" > "$FAKE_DIR/qga-path"; fi
  shift
done
: > "$console"
[[ $FAKE_MODE == btrfs ]] && { sleep 2; printf '[    3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0\n[    3.3] BTRFS: Read-only file system\n' >> "$console"; }
while :; do sleep 1; done
QEMU
cat > "$T/bin/ssh" <<'SSH'
#!/bin/bash
# Stand-in ssh: the VM answers unless it never comes up; poweroff stops QEMU.
# denied: our keys are turned down until the test puts the key in (key-in);
# denied-always: also after that.
[[ $FAKE_MODE == btrfs || $FAKE_MODE == down ]] && exit 255
if [[ $FAKE_MODE == denied-always || ( $FAKE_MODE == denied && ! -e $FAKE_DIR/key-in ) ]]; then
  echo "root@127.0.0.1: Permission denied (publickey)." >&2; exit 255
fi
kill -0 "$(cat "$FAKE_DIR/qemu.pid")" 2>/dev/null || exit 255
case ${*: -1} in
  "pacman -Q linux-aarch64-thp"*) echo "${FAKE_KERNEL:-}"; exit 0 ;;
  nproc) echo 8; exit 0 ;;
esac
# A guest takes a few seconds to power off: the update's watch ends first.
[[ ${*: -1} == "systemctl poweroff" ]] && { (sleep 5; kill "$(cat "$FAKE_DIR/qemu.pid")") & }
exit 0
SSH
cat > "$T/bin/curl" <<'CURL'
#!/bin/bash
# Stand-in curl: ALARM's kernel PKGBUILD.
printf 'pkgver=7.2.11\npkgrel=1\n'
CURL
cat > "$A/scripts/apply-vm.sh" <<'APPLY'
#!/bin/bash
# Stand-in apply: ok, or hangs (as an apply on a read-only VM did) until QEMU goes.
echo "${OMACVM_KERNEL_NEW:-unset}" > "$FAKE_DIR/kernel-new"
case $FAKE_MODE in
  ok|denied*) echo "==> OmacVM applied"; exit 0 ;;
  # An apply that takes 10 s (a kernel build, made short).
  slow) sleep 10; echo "==> OmacVM applied"; exit 0 ;;
  # The VM powers off by itself at the end, and the watch ends before the update does.
  ok-off) echo "==> OmacVM applied"; kill "$(cat "$FAKE_DIR/qemu.pid")"; sleep 5; exit 0 ;;
  ro) echo "touch: cannot touch '/usr/local/share/omacvm/x': Read-only file system" ;;
esac
while kill -0 "$(cat "$FAKE_DIR/qemu.pid")" 2>/dev/null; do sleep 1; done
echo "Connection to 127.0.0.1 closed by remote host." >&2
exit 255
APPLY
chmod +x "$A/runtime/bin/OmacVM" "$T/bin/ssh" "$T/bin/curl" "$A/scripts/apply-vm.sh"
V=$T/VMs/Copied; mkdir -p "$V"
printf "NAME='Copied'\nCPUS=2\nMEM_MB=4096\nDISK_GB=64\nSSH_PORT=52999\nVM_USER='me'\n" > "$V/vm.env"
: > "$V/disk.img"; : > "$V/efi-vars.fd"; : > "$V/ready"; : > "$T/key"

run() {   # MODE [VAR=VALUE...]: seconds, exit status, the update's ERROR or UPDATED line
  local mode=$1 start out rc; shift
  rm -f "$T/qemu.pid"; start=$(date +%s)
  env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$mode" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= "$@" \
    /bin/bash "$A/scripts/update-vm.sh" "$V" > "$T/out" 2>&1
  rc=$?
  out=$(grep -E '^(ERROR|UPDATED)' "$T/out" | tail -1)
  echo "$(( $(date +%s) - start )) $rc $out"
}
r=$(run btrfs); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "btrfs errors on the console: the update stops with the disk's error" "yes" \
  "$([[ $r == "ERROR: Copied's disk has errors, so the update stopped (the VM says: [    3.1] BTRFS error"* ]] && echo yes || echo "$r")"
expect "... and says what to do" "yes" "$([[ $r == *"shut it down on the Mac it came from and copy it again"* ]] && echo yes)"
expect "... within 40 s, not after the 5 minutes for SSH" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
expect "... and QEMU is gone" "gone" "$(kill -0 "$(cat "$T/qemu.pid")" 2>/dev/null && echo runs || echo gone)"
r=$(run ro); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a read-only file system in the apply: stops, the disk's error" "yes" \
  "$([[ $r == *"disk has errors"*"Read-only file system"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
r=$(run hang OMACVM_UPDATE_SECONDS=6); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "an apply that hangs: stopped after the update's time" "yes" \
  "$([[ $r == "ERROR: The update took too long, so it was stopped"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
r=$(run down OMACVM_UPDATE_SECONDS=6); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a VM that never comes up: stopped after the update's time" "yes" \
  "$([[ $r == "ERROR: The update took too long"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
expect "a stopped update fails (exit 1)" "1" "$rc"
r=$(run ok); r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a good update: no false alarm" "UPDATED Copied" "$r"
expect "... and exits 0" "0" "$rc"
r=$(run ok-off); r=${r#* }; rc=${r%% *}; r=${r#* }
expect "the VM off before the update ends: still UPDATED, exit 0 (the watch had ended)" "0 UPDATED Copied" "$rc $r"

# ---------- a newer memory-optimized kernel: asked, not built by itself ----------
expect "no memory-optimized kernel: no question, the apply keeps" "keep" "$(cat "$T/kernel-new")"
expect "... no ASK line" "" "$(grep '^ASK' "$T/out")"
printf 'bridge=on thp-kernel=on control-centre=on\n' > "$V/features"
krun() {   # ANSWER|none MODE [VAR=VALUE...]: the exit status and the last ERROR/UPDATED
  local a=$1 mode=$2 rc; shift 2
  rm -f "$T/qemu.pid" "$T/kernel-new"
  if [[ $a == none ]]; then
    sleep 6 | env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$mode" FAKE_KERNEL=7.2.10-1 OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= "$@" \
      /bin/bash "$A/scripts/update-vm.sh" "$V" > "$T/out" 2>&1
  else
    { sleep 1; echo "$a"; } | env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$mode" FAKE_KERNEL=7.2.10-1 OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= "$@" \
      /bin/bash "$A/scripts/update-vm.sh" "$V" > "$T/out" 2>&1
  fi
  rc=${PIPESTATUS[1]}
  echo "$rc $(grep -E '^(ERROR|UPDATED)' "$T/out" | tail -1)"
}
r=$(krun later ok)
expect "ALARM has a newer kernel: the app is asked (have, latest, CPUs, minutes)" "ASK kernel 7.2.10-1 7.2.11-1 8 20 30" "$(grep '^ASK' "$T/out")"
expect "Later: the update goes on and the VM keeps its kernel" "0 UPDATED Copied keep" "$r $(cat "$T/kernel-new")"
expect "... and says so" "1" "$(grep -c '^==> the memory-optimized kernel stays at 7.2.10-1' "$T/out")"
r=$(krun build ok)
expect "Build Now: the apply builds it" "0 UPDATED Copied build" "$r $(cat "$T/kernel-new")"
r=$(krun none ok OMACVM_ASK_SECONDS=3)
expect "no answer in time: later" "0 UPDATED Copied keep" "$r $(cat "$T/kernel-new")"
r=$(krun later slow OMACVM_UPDATE_SECONDS=6)
expect "the time it waits for an answer does not count; a long apply after Later still stops" "yes" "$([[ $r == "1 ERROR: The update took too long"* ]] && echo yes || echo "$r")"
r=$(krun build slow OMACVM_UPDATE_SECONDS=6)
expect "Build Now: the update gets the build's time" "0 UPDATED Copied" "$r"
r=$(krun build ok FAKE_KERNEL=7.2.11-1)
expect "the VM has ALARM's kernel: no question" "0 UPDATED Copied keep" "$r $(cat "$T/kernel-new")"
# ---------- wait_ssh: "refused" stops at the first Permission denied ----------
eval "$(sed -n '/^wait_ssh() {/,/^}/p' "$R/app/scripts/vm-common.sh")"
qemu_running() { [[ ! -e $T/qemu-gone ]]; }
sleep() { :; }
vssh() {   # Stand-in: line N of $T/seq is "STATUS|its error" for try N; past the end: connection refused.
  local n l; n=$(( $(cat "$T/tries") + 1 )); echo "$n" > "$T/tries"
  l=$(sed -n "${n}p" "$T/seq"); [[ -n $l ]] || l="255|ssh: connect to host 127.0.0.1 port 52999: Connection refused"
  echo "${l#*|}" >&2; return "${l%%|*}"
}
ws() { echo 0 > "$T/tries"; local rc=0; wait_ssh "$@" 2>/dev/null || rc=$?; echo "$rc $(cat "$T/tries")"; }
printf '%s\n' "255|ssh: connect to host 127.0.0.1 port 52999: Connection refused" "255|kex_exchange_identification: read: Connection reset by peer" \
  "255|root@127.0.0.1: Permission denied (publickey)." "0|" > "$T/seq"
expect "wait_ssh refused: 2 at the first Permission denied (try 3)" "2 3" "$(ws 30 refused)"
expect "wait_ssh without it: waits past it, as builds do" "0 4" "$(ws 30)"
printf '%s\n' "255|Connection closed by 127.0.0.1 port 52999" "0|" > "$T/seq"
expect "wait_ssh refused: a closed connection keeps it waiting" "0 2" "$(ws 30 refused)"
: > "$T/seq"
expect "wait_ssh refused: never up within the time: 1" "1 4" "$(ws 12 refused)"
expect "wait_ssh: never up within the time: 1" "1 4" "$(ws 12)"
touch "$T/qemu-gone"
expect "wait_ssh refused: QEMU gone: 1, no try" "1 0" "$(ws 30 refused)"
unset -f qemu_running sleep vssh ws wait_ssh

# ---------- Update VM: the key turned down, the app asked to add it ----------
rm -f "$V/features"
mkdir -p "$T/bin-nc"
cat > "$T/bin-nc/nc" <<'NC'
#!/bin/bash
# Stand-in nc for QMP: records the command; the power button or quit stop QEMU.
in=$(cat)
case $in in
  *system_powerdown*) echo powerdown >> "$FAKE_DIR/qmp.log"; kill "$(cat "$FAKE_DIR/qemu.pid")" ;;
  *'"quit"'*) echo quit >> "$FAKE_DIR/qmp.log"; kill "$(cat "$FAKE_DIR/qemu.pid")" ;;
esac
exit 0
NC
chmod +x "$T/bin-nc/nc"
srun() {   # MODE ANSWER|none [VAR=VALUE...]: the exit status; the update's output in $T/out
  local mode=$1 a=$2 rc; shift 2
  rm -f "$T/qemu.pid" "$T/key-in" "$T/qmp.log" "$T/qga-path"; : > "$T/out"
  { if [[ $a == none ]]; then sleep 6; else
      for _ in $(seq 100); do grep -q '^FIX ssh-key' "$T/out" && break; sleep 0.2; done
      [[ $a == added ]] && touch "$T/key-in"
      echo "$a"; sleep 1
    fi; } |
    env PATH="$T/bin-nc:$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$mode" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= OMACVM_FIX_SECONDS=2 "$@" \
      /bin/bash "$A/scripts/update-vm.sh" "$V" > "$T/out" 2>&1
  rc=${PIPESTATUS[1]}
  echo "$rc"
}
rm -f "$V/ssh-key" "$V/ssh-key.pub"
rc=$(srun denied added)
expect "turned down, the app adds the key: the update goes on" "0" "$rc"
expect "... the app was asked once (FIX ssh-key)" "1" "$(grep -c '^FIX ssh-key$' "$T/out")"
expect "... says so, then that SSH works again" "yes" \
  "$(grep -q "^==> Copied doesn't know this VM folder's SSH key: adding it" "$T/out" && grep -q '^==> SSH works again.' "$T/out" && echo yes)"
expect "... and ends UPDATED" "UPDATED Copied" "$(grep '^UPDATED' "$T/out")"
expect "... the folder had no key: a new one, said once" "1" "$(grep -c '^==> this VM folder had no SSH key: made a new one' "$T/out")"
agent=$(cat "$T/qga-path" 2>/dev/null)
expect "... QEMU had the guest agent's port at the window's path" "$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(printf '%s' "$V" | shasum | cut -c1-8).qga" "$agent"
expect "... and its socket is gone after the update" "gone" "$([[ -n $agent && ! -e $agent ]] && echo gone || echo "there: $agent")"
s=$(date +%s); rc=$(srun denied none)
expect "no answer from the app (no guest agent): stops (exit 1)" "1" "$rc"
expect "... SSHKEY refused, for Copy Command" "1" "$(grep -c '^SSHKEY refused$' "$T/out")"
expect "... the error says what to do" "yes" \
  "$(grep -q "^ERROR: Copied doesn't let this Mac in over SSH, and OmacVM could not add this VM folder's key (the VM's guest agent did not answer).*Copy Command.*Update VM again" "$T/out" && echo yes || grep '^ERROR' "$T/out")"
expect "... the VM goes off by its power button, no QMP quit" "powerdown" "$(paste -sd ' ' "$T/qmp.log" 2>/dev/null)"
expect "... within 20 s" "yes" "$( (( $(date +%s) - s < 20 )) && echo yes || echo "$(( $(date +%s) - s )) s")"
rc=$(srun denied failed)
expect "the app could not add it: stops, says so" "1 yes" \
  "$rc $(grep -q "could not add this VM folder's key (adding it in the VM failed)" "$T/out" && grep -q '^SSHKEY refused$' "$T/out" && echo yes)"
rc=$(srun denied-always added)
expect "added, but SSH still turns it down: stops" "1" "$rc"
expect "... says the VM's SSH settings may have changed" "yes" "$(grep -q "^ERROR: OmacVM added this VM folder's key in Copied, but its SSH still turns OmacVM away" "$T/out" && echo yes)"
expect "... no Copy Command there (it would not help)" "0" "$(grep -c '^SSHKEY refused' "$T/out")"
rc=$(srun denied-always present)
expect "there already, but SSH still turns it down: stops, says it was there" "1 yes" \
  "$rc $(grep -q "^ERROR: Copied already has this VM folder's key, but its SSH still turns OmacVM away" "$T/out" && echo yes)"
rc=$(srun ok none)
expect "a VM that lets us in: no FIX line, UPDATED" "0 0 UPDATED Copied" "$rc $(grep -c '^FIX' "$T/out") $(grep '^UPDATED' "$T/out")"
expect "... and no new key" "0" "$(grep -c 'made a new one' "$T/out")"
exit $fail
