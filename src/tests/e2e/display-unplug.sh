#!/bin/bash
# The VM lives on when the display its window is on is unplugged (#402). Part of
# the release gate (cc-switches.sh, step "unplug"); also alone on a test Mac.
# A macOS virtual display (app/scripts/dev/virtual-display.m: 6K Retina, like a
# Pro Display XDR; a new serial each time) is plugged in and taken away while a
# real VM of the test identity has its window there:
#   full       full screen on it (the menu bar's display), one window per
#              display on the other one: --rounds rounds (default 3)
#   fullpanel  "Full screen including notch" (a made-up notch,
#              OMACVM_TEST_NOTCH_GEOMETRY): 2 rounds; QEMU crashed here (3.1.7)
#   window     a window on it: 1 round
# After each unplug: the same QEMU still runs 8 s later, the VM answers over
# SSH, and no new crash report of the app's QEMU.
#
#   src/tests/e2e/display-unplug.sh --vm NAME [--rounds N] [--only LIST] [--out DIR]
#     --only LIST   cases (comma list): full,fullpanel,window (default: all)
#     --out DIR     summary.tsv and the logs (default ~/omacvm-e2e/unplug-<time>)
# Needs: ~/Applications/"OmacVM Test.app" (org.omacvm.app.test), NAME stopped in
# its VMs folder, clang (builds the display tool), and the test Mac to itself:
# the caller holds its lock (cc-switches.sh does), nobody uses it, no other VM
# runs (a display going changes every window on the Mac). The test app's
# startFullScreen and the VM's notch-mode are put back as they were.
# Exit 0 only when every unplug passed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)

VM=""; ROUNDS=3; ONLY=""; OUT=""
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "usage: display-unplug.sh --vm NAME [--rounds N] [--only full,fullpanel,window] [--out DIR]" >&2; exit 2 ;;
  esac
done
[[ -n $VM ]] || { echo "display-unplug: --vm NAME (a test VM)" >&2; exit 2; }
[[ $ROUNDS =~ ^[1-9][0-9]?$ ]] || { echo "display-unplug: --rounds 1-99" >&2; exit 2; }
want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }

export OMACVM_TEST_IDENTITY=1
APP="$HOME/Applications/OmacVM Test.app"
APPID=org.omacvm.app.test
KEY=$HOME/.ssh/omacvm
NOTCH=645.5x824.5x34x1470x956   # a 14" MacBook Pro's notch, in points
OUT=${OUT:-$HOME/omacvm-e2e/unplug-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
: > "$OUT/summary.tsv"
n_fail=0
res() {   # STEP ok|FAIL|skip DETAIL
  printf '%s\t%s\t%s\n' "unplug-$1" "$2" "$3" >> "$OUT/summary.tsv"
  printf '%-34s %-7s %s\n' "unplug-$1" "$2" "$3"
  [[ $2 == FAIL ]] && n_fail=$((n_fail + 1))
  return 0
}
log() { echo "== $(date +%H:%M:%S) $*"; }

VMD=$( (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") 2>&1) || { echo "display-unplug: $VMD" >&2; exit 2; }
QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
qemu_pid() { pgrep -f "$QPAT $VM( |$)" | head -1; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'"; }
gssh() { ssh -i "$KEY" -p "$(port)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@" < /dev/null; }
# Every QEMU on this Mac but this VM's (the person's VM above all): none may run.
others() { pgrep -fl "qemu-system-aarch64|runtime/bin/OmacVM -name|MacOS/OmacVM-VM -name" | grep -v -E "$QPAT $VM( |$)"; }
[[ -z $(others) ]] || { echo "display-unplug: another VM runs (a display going moves its windows too): $(others | head -1)" >&2; exit 3; }
[[ -z $(qemu_pid) ]] || { echo "display-unplug: $VM runs: stop it first" >&2; exit 3; }
crashes() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^OmacVM-.*\.ips$'; }

# The display tool, built here.
VD="$OUT/virtual-display"
clang -fobjc-arc -framework Foundation -framework CoreGraphics "$R/app/scripts/dev/virtual-display.m" -o "$VD" \
  > "$OUT/build-tool.log" 2>&1 || { echo "display-unplug: could not build the display tool ($OUT/build-tool.log)" >&2; exit 3; }
VD_PID=""; VD_ID=""
plug() {   # the virtual display, with the menu bar on it
  local f="$OUT/vd.out" i
  "$VD" 3008x1692 --hidpi --main --name "OmacVM Unplug Test $RANDOM" > "$f" 2>&1 &
  VD_PID=$!
  for ((i = 0; i < 30; i++)); do VD_ID=$(sed -n 's/^id=//p' "$f"); [[ -n $VD_ID ]] && break; sleep 0.5; done
  [[ -n $VD_ID ]] || { kill "$VD_PID" 2>/dev/null; VD_PID=""; return 1; }
  sleep 3
}
unplug() { [[ -n $VD_PID ]] && { kill "$VD_PID" 2>/dev/null; wait "$VD_PID" 2>/dev/null; }; VD_PID=""; VD_ID=""; }

# Put back what this changes, also on Ctrl-C.
FS_BEFORE=$(defaults read "$APPID" startFullScreen 2>/dev/null || echo unset)
NOTCH_BEFORE=$(cat "$VMD/notch-mode" 2>/dev/null || echo none)
restore() {
  unplug
  local p; p=$(qemu_pid)
  if [[ -n $p ]]; then
    gssh "systemctl poweroff" >/dev/null 2>&1
    for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  fi
  if [[ $FS_BEFORE == unset ]]; then defaults delete "$APPID" startFullScreen 2>/dev/null
  else defaults write "$APPID" startFullScreen -bool "$( [[ $FS_BEFORE == 1 ]] && echo true || echo false)"; fi
  if [[ $NOTCH_BEFORE == none ]]; then rm -f "$VMD/notch-mode"; else echo "$NOTCH_BEFORE" > "$VMD/notch-mode"; fi
}
trap restore EXIT

start() {   # window|full|fullpanel, on the virtual display
  local mode=$1 i env=(--env "OMACVM_TEST_MAIN_DISPLAY=$VD_ID" --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e)
  rm -f "$VMD/notch-mode"
  case $mode in
    window) defaults write "$APPID" startFullScreen -bool false ;;
    full) defaults write "$APPID" startFullScreen -bool true ;;
    fullpanel) defaults write "$APPID" startFullScreen -bool true; echo fullpanel > "$VMD/notch-mode"
               env+=(--env "OMACVM_TEST_NOTCH_GEOMETRY=$NOTCH") ;;
  esac
  (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") >/dev/null || return 1
  open -n "${env[@]}" "$APP" --args --start --vm "$VM"
  for ((i = 0; i < 40; i++)); do [[ -n $(qemu_pid) ]] && break; sleep 1; done
  [[ -n $(qemu_pid) ]] || return 1
  # The desktop up (its display agent moves the outputs), then a moment for full screen.
  for ((i = 0; i < 90; i++)); do gssh "test -d /run/user/\$(id -u \$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env))/hypr" 2>/dev/null && { sleep 25; return 0; }; sleep 2; done
  return 1
}
stop() {
  local p i; p=$(qemu_pid); [[ -n $p ]] || return 0
  gssh "systemctl poweroff" >/dev/null 2>&1
  for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  ! kill -0 "$p" 2>/dev/null
}
case_run() {   # NAME MODE ROUNDS
  local name=$1 mode=$2 rounds=$3 pid r c0 l0 new
  log "$name: $mode on a virtual display, $rounds unplug(s)"
  plug || { res "$name" FAIL "no virtual display"; return; }
  start "$mode" || { res "$name" FAIL "the VM did not come up on the virtual display"; unplug; stop; return; }
  pid=$(qemu_pid)
  [[ $mode == fullpanel ]] && res "$name-start" ok "$(grep -h 'OmacVM: notch area:' "$VMD/logs/qemu.log" | tail -1 | cut -c1-100)"
  for ((r = 1; r <= rounds; r++)); do
    c0=$(crashes); l0=$(wc -l < "$VMD/logs/qemu.log")
    unplug
    sleep 8
    tail -n +$((l0 + 1)) "$VMD/logs/qemu.log" > "$OUT/$name-$r-qemu.log" 2>/dev/null
    new=$(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep '^OmacVM-.*\.ips$' | head -1)
    if ! kill -0 "$pid" 2>/dev/null; then
      res "$name-$r" FAIL "QEMU ended at the unplug$( (( $(crashes) > c0 )) && echo ": crash report $new")"
      break
    elif ! gssh true; then
      res "$name-$r" FAIL "QEMU runs, but the VM does not answer over SSH"
      break
    elif (( $(crashes) > c0 )); then
      res "$name-$r" FAIL "a new crash report: $new"
      break
    fi
    res "$name-$r" ok "QEMU $pid runs on, the VM answers"
    (( r < rounds )) && { plug || { res "$name-plug-$r" FAIL "no virtual display"; break; }; sleep 12; }
  done
  unplug
  stop || res "$name-stop" FAIL "the VM did not shut down"
  sleep 3
}

want full && case_run full full "$ROUNDS"
want fullpanel && case_run fullpanel fullpanel 2
want window && case_run window window 1
log "done: $n_fail failed ($OUT/summary.tsv)"
(( n_fail == 0 ))
