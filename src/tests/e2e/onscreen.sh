#!/bin/bash
# The on-screen release test: what a person sees and clicks in OmacVM.app,
# with real clicks and pointer moves (HID events) and Accessibility on the
# app's own processes, on a test VM. One row per check in summary.tsv, a
# screenshot when a check on screen fails.
#   window          the app's window opens 800 pt wide, at most 800 tall, centred on its display,
#                   and stays 800 wide after a double-click on its title bar (and a second one)
#   update-vm       Update VM in the window (the VM's OmacVM made older first) runs to UPDATED
#   switch-stopped  "WebGPU and GPU compute" switched in the window with the VM stopped; Start in
#                   the window applies it (#445); the second start switches it back
#   vm-size         the VM's window keeps its size after full screen and back, twice (#452)
#   pointer         the Mac's cursor shows nothing over the VM while the guest draws its pointer:
#                   coming in, after a background program shows the cursor (as OmacVM Gestures
#                   did up to 3.1.24), after switching to Finder and back; in the window and in
#                   full screen; with "Graphics without QEMU's lock" off and on (switched in the
#                   window between the two starts)
#   leftovers       nothing of the VM or the app runs on after the VM shut down from inside,
#                   after its window was closed, and after the app quit
# On screen only while nobody uses the Mac (no input for 300 s but ours, no
# Jump Desktop session, the screen unlocked); it stops when someone comes back.
# Without that (or with --headless) the on-screen rows are BLOCKED, and
# update-vm (update-vm.sh, as the window runs it) and leftovers (a start
# without a window) run headless.
#   src/tests/e2e/onscreen.sh --app "PATH/OmacVM Test.app" --vm NAME [--out DIR]
#       [--only ROW,...] [--headless]
# NAME: a stopped test VM in the test app's VMs folder (e2e_vm_guard). The
# caller holds the Mac's VM lock. The app's settings this changes are put back.
# Results: OUT/summary.tsv, OUT/result.json (kind omacvm-e2e-onscreen, pass),
# OUT/shots/, OUT/run.log. Exit 0 passed, 1 a check failed, 2 usage, 3 not
# run in full (BLOCKED).
set -uo pipefail
E=$(cd "$(dirname "$0")" && pwd)
source "$E/test-vms.sh"
source "$E/onscreen-lib.sh"
ALL="window update-vm switch-stopped vm-size pointer leftovers"
APP=""; VM=""; OUT=""; ONLY=""; HEADLESS=0
usage() { sed -n '24,25s/^# \{0,1\}//p' "$0" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --app) APP=${2%/}; shift 2 ;;
    --vm) VM=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --only) ONLY=" ${2//,/ } "; shift 2 ;;
    --headless) HEADLESS=1; shift ;;
    *) usage ;;
  esac
done
[[ -n $APP && -n $VM ]] || usage
for r in $ONLY; do [[ " $ALL " == *" $r "* ]] || { echo "onscreen: no row $r (rows: $ALL)" >&2; exit 2; }; done
PB=/usr/libexec/PlistBuddy
DOM=$($PB -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
[[ $DOM == org.omacvm.app.test* ]] || { echo "onscreen: $APP is not a test identity build (bundle id '$DOM')" >&2; exit 2; }
VMD=$(e2e_vm_guard "$DOM" "$VM") || exit 2
VER=$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
COMMIT=$($PB -c "Print :OmacVMCommit" "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
OUT=${OUT:-$HOME/omacvm-e2e/onscreen-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/shots" "$OUT/bin" "$OUT/saved" || exit 2
S=$OUT/summary.tsv; : > "$S"
exec > >(tee -a "$OUT/run.log") 2>&1
T=$OUT/bin/onscreen-tool
xcrun swiftc -O "$E/onscreen-tool.swift" -o "$T" >"$OUT/bin/build.log" 2>&1 || { echo "onscreen: the tool did not build ($OUT/bin/build.log)"; exit 2; }
T0=$(date +%s); LAST=0; GONE=""

log() { echo "== $(date +%H:%M:%S) $*"; }
res() { printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$1" "$2" "$3" >> "$S"; printf '%-8s %-22s %s\n' "$2" "$1" "$3"; }
want() { [[ -z $ONLY || $ONLY == *" $1 "* ]]; }

# --- the Mac and its user
hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
jump() { pgrep -f 'JumpConnect.*(rtcproxy|desktopproxy)' | wc -l | tr -d ' '; }
locked() { ioreg -n Root -d1 -k IOConsoleUsers 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes' && echo Yes || echo No; }
away() { os_away "$(hid_idle)" "$(jump)" "$(locked)" "$LAST" "$(date +%s)"; }
who() { echo "HID idle $(hid_idle) s, Jump sessions $(jump), screen locked $(locked)"; }
posted() { LAST=$(date +%s); }
# On screen from here on only while nobody else uses the Mac; else remembers why and says no.
onscreen_ok() {
  [[ -z $GONE ]] || return 1
  away && return 0
  GONE="someone uses the Mac since $(date +%H:%M:%S) ($(who))"; log "STOP on screen: $GONE"; return 1
}
shot() { screencapture -x -C "$OUT/shots/$1.png" 2>/dev/null && sips -Z 1600 "$OUT/shots/$1.png" >/dev/null 2>&1; }
spot() {   # NAME X Y: the 240 pt around the pointer, with the cursor
  screencapture -x -C -R "$(( $2 - 120 )),$(( $3 - 120 )),240,240" "$OUT/shots/$1.png" 2>/dev/null
}

# --- the app and the VM
psall() { ps -axww -o pid=,args=; }
pid_of() {   # EXECUTABLE [MATCH]: the pid whose command is EXECUTABLE (and has MATCH)
  psall | awk -v x="$1" -v m="${2:-}" '{ p = $1; a = $0; sub(/^ *[0-9]+ +/, "", a)
    if ((a == x || index(a, x " ") == 1) && (m == "" || index(a, m))) { print p; exit } }'
}
launcher_pid() { pid_of "$APP/Contents/MacOS/OmacVM"; }
qemu_pid() { local p; p=$(pid_of "$APP/Contents/MacOS/OmacVM-VM" " -name $VM"); [[ -n $p ]] || p=$(pid_of "$APP/Contents/Resources/runtime/bin/OmacVM" " -name $VM"); echo "$p"; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'\"" | head -1; }
gssh() { ssh -i "$VMD/ssh-key" -i "$HOME/.ssh/omacvm" -p "$(port)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@" </dev/null; }
QLOG=$VMD/logs/qemu.log; QOFF=0
qmark() { QOFF=$(stat -f %z "$QLOG" 2>/dev/null || echo 0); }
qnew() { tail -c +$(( QOFF + 1 )) "$QLOG" 2>/dev/null | tr -d '\000'; }
waitfor() {   # SECONDS COMMAND...: until COMMAND succeeds
  local n=$1 i; shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 1; done; "$@"
}
has_qemu() { [[ -n $(qemu_pid) ]]; }
no_qemu() { [[ -z $(qemu_pid) ]]; }
no_launcher() { [[ -z $(launcher_pid) ]]; }
has_launcher() { [[ -n $(launcher_pid) ]]; }
has_window() { [[ -n $(win_of "$LP") ]]; }
updating() { psall | grep -v grep | grep -qF "update-vm.sh $VMD"; }
wid() { awk '{printf "%.0f", $3}' <<<"$1"; }
guest_up() { qnew | grep -q 'the guest draws its own pointer now' && gssh true 2>/dev/null; }
win_of() { "$T" win "$1" 2>/dev/null | cut -d' ' -f1-4; }
is_full() { [[ $("$T" win "$1" 2>/dev/null) == *full=$2 ]]; }
# What is left of this run besides PID (the launcher, when it stays)
leftovers() { psall | os_leftovers "$APP" "$VMD" "$VM" | awk -v k="${1:-x}" '$1 != k' | cut -c1-200; }
feature() { grep -o "^$1=[a-z]*" "$VMD/features" 2>/dev/null | tail -1 | cut -d= -f2; }
pending() { tr -d '\n' < "$VMD/$1-pending" 2>/dev/null; }

# --- settings this run changes: saved, put back at the end
KEYS="startFullScreen gpuOffMainLoop closeAction"
cleanup() {
  local p
  p=$(qemu_pid); [[ -n $p ]] && { gssh systemctl poweroff >/dev/null 2>&1; waitfor 90 no_qemu >/dev/null || log "the VM did not shut down"; }
  p=$(launcher_pid); [[ -n $p ]] && { "$T" quit "$p" >/dev/null 2>&1; waitfor 20 no_launcher >/dev/null || kill "$p" 2>/dev/null; }
  # shellcheck disable=SC2086
  e2e_settings_restore "$DOM" "$OUT/saved" $KEYS || log "settings: not all put back"
  [[ -f $OUT/saved/omacvm-version ]] && ! grep -q "^$VER\$" "$VMD/omacvm-version" 2>/dev/null && cp "$OUT/saved/omacvm-version" "$VMD/omacvm-version"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log "onscreen: $APP ($VER, $COMMIT, $DOM), VM $VMD, macOS $(sw_vers -productVersion), $(who)"
[[ -z $(qemu_pid) ]] || { echo "onscreen: $VM runs: shut it down first"; exit 2; }
[[ -z $(launcher_pid) ]] || { echo "onscreen: $APP runs: quit it first"; exit 2; }
# shellcheck disable=SC2086
e2e_settings_save "$DOM" "$OUT/saved" $KEYS || exit 2
defaults write "$DOM" startFullScreen -bool false
defaults write "$DOM" closeAction shutdown
GPU0=$(defaults read "$DOM" gpuOffMainLoop 2>/dev/null || echo 0)
GC0=$(feature gpu-compute); cp "$VMD/omacvm-version" "$OUT/saved/omacvm-version" 2>/dev/null

# --- rows

row_window() {   # the launcher's window (VM stopped)
  local p f s pr a f2 f3 x y w h
  p=$LP; f=$(win_of "$p"); [[ -n $f ]] || { res window FAIL "no window"; shot window; return; }
  read -r x y w h <<<"$f"
  s=$("$T" screen $(( x + w / 2 )) $(( y + h / 2 )))
  pr=$(os_window_problems "$f" "$s" | tr '\n' ';')
  [[ -z $pr ]] && res window ok "frame $f on the display's visible $s" || { res window FAIL "frame $f on the display's visible $s: $pr"; shot window-open; }
  a=$(defaults read -g AppleActionOnDoubleClick 2>/dev/null || echo "Fill (default)")
  case $a in Minimize|None) res window-title-click skip "a title-bar double-click is set to '$a' on this Mac"; return ;; esac
  onscreen_ok || return
  [[ $("$T" front "$p") == front ]] || { res window-title-click FAIL "the window did not come to the front"; return; }
  # The title bar's middle, above the header's controls.
  posted; "$T" dclick "$p" $(( x + w / 2 )) $(( y + 6 )) >/dev/null || { res window-title-click FAIL "no double-click: the point is not the window's"; return; }
  sleep 2; f2=$(win_of "$p")
  read -r x y w h <<<"$f2"
  posted; "$T" dclick "$p" $(( x + w / 2 )) $(( y + 6 )) >/dev/null; sleep 2; f3=$(win_of "$p")
  if [[ $f2 == "$f" && $f3 == "$f" ]]; then res window-title-click skip "the double-clicks changed nothing ($a): frame $f"
  elif (( $(wid "$f2") >= 799 && $(wid "$f2") <= 801 && $(wid "$f3") >= 799 && $(wid "$f3") <= 801 )); then
    res window-title-click ok "$a: $f -> $f2 -> $f3"
  else res window-title-click FAIL "$a: $f -> $f2 -> $f3 (not 800 wide)"; shot window-title-click; fi
}

row_update_vm() {   # Update VM in the window: the VM's OmacVM made older first (before the window opened)
  local p=$LP t0 i asked="" r
  if ! r=$("$T" find "$p" AXButton "Update VM" 2>&1); then res update-vm FAIL "no Update VM button (VM's OmacVM $(cat "$VMD/omacvm-version"))"; shot update-vm; return; fi
  [[ $r == enabled=1* ]] || { res update-vm FAIL "Update VM is disabled: $r"; return; }
  onscreen_ok || return
  : > "$VMD/update.log" 2>/dev/null
  "$T" front "$p" >/dev/null; posted; r=$("$T" click "$p" AXButton "Update VM")
  t0=$(date +%s)
  for ((i = 0; i < 300; i++)); do   # 15 min
    grep -q '^UPDATED ' "$VMD/update.log" 2>/dev/null && break
    grep -q '^ERROR' "$VMD/update.log" 2>/dev/null && break
    (( i > 20 )) && ! updating && no_qemu && break   # ended without a word
    if [[ -z $asked ]] && "$T" find "$p" AXButton Later >/dev/null 2>&1; then
      asked="kernel question answered Later"; onscreen_ok && { posted; "$T" click "$p" AXButton Later >/dev/null; }
    fi
    sleep 3
  done
  waitfor 60 no_qemu >/dev/null
  if grep -q '^UPDATED ' "$VMD/update.log" 2>/dev/null && [[ $(tr -d '\n' < "$VMD/omacvm-version") == "$VER" ]]; then
    res update-vm ok "$r; UPDATED in $(( $(date +%s) - t0 )) s, the VM's OmacVM $VER${asked:+, $asked}"
  else
    res update-vm FAIL "$r; after $(( $(date +%s) - t0 )) s: $(grep -v '^ *$' "$VMD/update.log" 2>/dev/null | tail -3 | tr '\n' '|' | cut -c1-300)"
    shot update-vm; cp "$VMD/update.log" "$VMD/logs/omacvm-update.log" "$OUT/" 2>/dev/null
  fi
}

update_vm_headless() {
  local t0 rc
  t0=$(date +%s)
  OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=$DOM OMACVM_PROGRESS=1 perl -e 'alarm 900; exec @ARGV' /bin/bash "$APP/Contents/Resources/scripts/update-vm.sh" "$VMD" > "$OUT/update-vm.log" 2>&1 < /dev/null; rc=$?
  if (( rc == 0 )) && grep -q '^UPDATED ' "$OUT/update-vm.log" && [[ $(tr -d '\n' < "$VMD/omacvm-version") == "$VER" ]]; then
    res update-vm ok "headless (update-vm.sh, the window's path without the click): UPDATED in $(( $(date +%s) - t0 )) s, the VM's OmacVM $VER"
  else res update-vm FAIL "headless: rc $rc after $(( $(date +%s) - t0 )) s: $(tail -3 "$OUT/update-vm.log" | tr '\n' '|' | cut -c1-300)"; fi
}

switch_stopped() {   # N: "WebGPU and GPU compute" flipped with the VM stopped
  local n=$1 p=$LP r before want
  before=$(feature gpu-compute); [[ $before == on ]] && want=off || want=on
  "$T" front "$p" >/dev/null; posted; "$T" click "$p" AXButton General >/dev/null 2>&1; sleep 1
  r=$("$T" find "$p" AXCheckBox "WebGPU and GPU compute" 2>&1)
  [[ $r == enabled=1* ]] || { res "switch-stopped-$n" FAIL "the switch cannot be used with the VM stopped: $r"; shot "switch-stopped-$n"; return 1; }
  onscreen_ok || return 1
  posted; r=$("$T" click "$p" AXCheckBox "WebGPU and GPU compute")
  waitfor 10 test_eq_feature "$want" >/dev/null
  if [[ $(feature gpu-compute) == "$want" && $(pending gpu-compute) == "$want" ]]; then
    res "switch-stopped-$n" ok "$r; record $before -> $want, applies at the next start"; SW_WANT=$want
  else res "switch-stopped-$n" FAIL "$r; record $(feature gpu-compute) (want $want), pending '$(pending gpu-compute)'"; shot "switch-stopped-$n"; return 1; fi
}
test_eq_feature() { [[ $(feature gpu-compute) == "$1" && $(pending gpu-compute) == "$1" ]]; }

start_in_window() {   # N: Start clicked in the window; the VM's window up, the guest's pointer drawn
  local n=$1 r
  onscreen_ok || return 1
  qmark; "$T" front "$LP" >/dev/null; posted; r=$("$T" click "$LP" AXButton Start)
  waitfor 60 has_qemu >/dev/null || { res "start-$n" FAIL "$r; no QEMU after 60 s"; shot "start-$n"; return 1; }
  QP=$(qemu_pid)
  waitfor 30 is_full "$QP" 0 >/dev/null
  waitfor 240 guest_up >/dev/null || { res "start-$n" FAIL "$r; the guest did not come up in 4 min"; shot "start-$n"; return 1; }
  sleep 5
  res "start-$n" ok "$r; QEMU $QP, window $(win_of "$QP"), $(qnew | grep -a -o 'virgl runs with[a-z ]*the BQL' | tail -1)"
}

switch_applied() {   # N: the start applied the switch
  local n=$1 line i
  for ((i = 0; i < 120; i++)); do
    line=$(qnew | grep -a -E "WebGPU and GPU compute $SW_WANT \(switched while the VM was stopped\): (set up in the VM|not set up)" | tail -1)
    [[ -n $line ]] && break; sleep 2
  done
  if [[ $line == *"set up in the VM"* && -z $(pending gpu-compute) ]]; then res "switch-applied-$n" ok "${line##*OmacVM: }"
  else res "switch-applied-$n" FAIL "qemu.log: ${line:-no line in 4 min}; pending '$(pending gpu-compute)'"; fi
}

row_vm_size() {
  local f0 f i bad=""
  f0=$(win_of "$QP"); [[ -n $f0 ]] || { res vm-size FAIL "no VM window"; return; }
  for i in 1 2; do
    onscreen_ok || return
    "$T" full "$QP" on >/dev/null; waitfor 15 is_full "$QP" 1 >/dev/null || bad+="no full screen ($i); "; sleep 2
    "$T" full "$QP" off >/dev/null; waitfor 15 is_full "$QP" 0 >/dev/null || bad+="did not leave full screen ($i); "; sleep 2
    f=$(win_of "$QP"); os_same_size "$f0" "$f" || bad+="after full screen $i: $f; "
  done
  [[ -z $bad ]] && res vm-size ok "$f0 kept over 2 full screens" || { res vm-size FAIL "before $f0: $bad"; shot vm-size; }
}

PT_BAD=""
look() {   # STEP: the Mac shows no cursor over the VM now
  local s; s=$("$T" cursor)
  if os_cursor_hidden "$s"; then PT_OK+="$1; "
  else PT_BAD+="$1: $s; "; local x y; x=${s##* at }; y=${x#*,}; x=${x%,*}; spot "pointer-$PT_N-$(echo "$1" | tr -c 'a-z0-9' '-')" "$x" "$y"; fi
}
in_vm() {   # X Y X2 Y2: a pointer move inside our VM's window
  posted; "$T" move "$1" "$2" "$3" "$4" 12 12 >/dev/null; sleep 1.2
}
row_pointer() {   # N
  PT_N=$1; PT_OK=""; PT_BAD=""
  local f x y w h cx cy finder mode
  mode=$(qnew | grep -a -o 'virgl runs with[a-z ]*the BQL' | tail -1); mode=${mode#virgl runs }
  finder=$(pgrep -x Finder | head -1)
  onscreen_ok || return
  [[ $("$T" front "$QP") == front ]] || { res "pointer-$1" FAIL "the VM did not come to the front"; return; }
  read -r x y w h <<<"$(win_of "$QP")"; cx=$(( x + w / 2 )); cy=$(( y + h / 2 ))
  posted; "$T" move $(( x - 12 )) "$cy" "$cx" "$cy" 20 10 >/dev/null; sleep 1.5; look "window: in"
  "$T" bg-show >/dev/null; in_vm "$cx" "$cy" $(( cx + 30 )) $(( cy + 20 )); look "window: a background program showed it"
  onscreen_ok || return
  [[ -n $finder ]] && { "$T" front "$finder" >/dev/null; sleep 1.5; }
  "$T" front "$QP" >/dev/null; sleep 1; in_vm $(( cx + 30 )) $(( cy + 20 )) "$cx" "$cy"; look "window: Finder and back"
  onscreen_ok || return
  "$T" full "$QP" on >/dev/null; waitfor 15 is_full "$QP" 1 >/dev/null; sleep 2
  read -r x y w h <<<"$(win_of "$QP")"; cx=$(( x + w / 2 )); cy=$(( y + h / 2 ))
  in_vm $(( cx - 40 )) "$cy" "$cx" "$cy"; look "full screen: in"
  "$T" bg-show >/dev/null; in_vm "$cx" "$cy" $(( cx + 30 )) $(( cy + 20 )); look "full screen: a background program showed it"
  onscreen_ok || return
  [[ -n $finder ]] && { "$T" front "$finder" >/dev/null; sleep 2; }
  "$T" front "$QP" >/dev/null; sleep 2; in_vm $(( cx + 30 )) $(( cy + 20 )) "$cx" "$cy"; look "full screen: Finder and back"
  "$T" full "$QP" off >/dev/null; waitfor 15 is_full "$QP" 0 >/dev/null; sleep 2
  if [[ -z $PT_BAD ]]; then res "pointer-$1" ok "graphics $mode: no Mac cursor over the VM at $(echo "$PT_OK" | tr -cd ';' | wc -c | tr -d ' ') checks"
  else res "pointer-$1" FAIL "graphics $mode: the Mac's cursor shows over the VM: $PT_BAD"; fi
}

stopped_left() {   # ROW HOW: after the VM stopped (HOW), nothing of it runs on
  local l
  waitfor 120 no_qemu >/dev/null || { res "$1" FAIL "$2: QEMU still runs after 2 min"; return 1; }
  sleep 5; l=$(leftovers "$(launcher_pid)")
  [[ -z $l ]] && res "$1" ok "$2: QEMU gone, nothing of the VM left" || res "$1" FAIL "$2: still running: $(echo "$l" | tr '\n' '|')"
}
quit_left() {   # ROW: the app quit (as Command-Q), nothing of it runs on
  local p l; p=$(launcher_pid)
  [[ -n $p ]] && { "$T" quit "$p" >/dev/null; waitfor 20 no_launcher >/dev/null || { res "$1" FAIL "the app did not quit in 20 s"; return 1; }; }
  sleep 3; l=$(leftovers)
  [[ -z $l ]] && res "$1" ok "app quit: nothing of it or the VM left" || res "$1" FAIL "after quitting: still running: $(echo "$l" | tr '\n' '|')"
}

gpu_lock_switch() {   # "Graphics without QEMU's lock" switched in the window (VM stopped)
  local r before after
  before=$(defaults read "$DOM" gpuOffMainLoop 2>/dev/null || echo 0)
  "$T" front "$LP" >/dev/null; posted; r=$("$T" click "$LP" AXCheckBox "Graphics without QEMU's lock" 2>&1); sleep 1.5
  after=$(defaults read "$DOM" gpuOffMainLoop 2>/dev/null || echo 0)
  [[ $after != "$before" ]] && res gpu-lock-switch ok "$r; gpuOffMainLoop $before -> $after" || res gpu-lock-switch FAIL "$r; gpuOffMainLoop stays $before"
}

open_window() {
  open -n --env OMACVM_POINTER_DEBUG=1 "$APP" --args --vm "$VM"
  waitfor 30 has_launcher >/dev/null || return 1
  LP=$(launcher_pid)
  waitfor 30 has_window
}

headless_leftovers() {
  qmark
  open -n -g --env OMACVM_COCOA_HIDDEN=1 --env OMACVM_BACKGROUND=1 "$APP" --args --start --vm "$VM"
  waitfor 60 has_qemu >/dev/null || { res leftovers FAIL "headless: no QEMU after 60 s"; return; }
  waitfor 240 gssh true >/dev/null 2>&1 || { res leftovers FAIL "headless: no SSH in 4 min"; return; }
  gssh systemctl poweroff >/dev/null 2>&1
  stopped_left leftovers-stop "headless start, shut down from inside" && quit_left leftovers-quit
}

# --- the run
if (( HEADLESS )); then GONE="--headless"; elif ! away; then GONE="someone uses the Mac ($(who))"; fi
if [[ -z $GONE ]]; then
  log "on screen: nobody uses the Mac ($(who))"
  want update-vm && echo 3.0.0 > "$VMD/omacvm-version"   # older than the app: the window offers Update VM
  if open_window; then
    want window && row_window
    want update-vm && onscreen_ok && row_update_vm
    for n in 1 2; do
      onscreen_ok || break
      SW_WANT=""
      want switch-stopped && { switch_stopped "$n" || true; }
      start_in_window "$n" || break
      [[ -n $SW_WANT ]] && switch_applied "$n"
      (( n == 1 )) && want vm-size && row_vm_size
      want pointer && row_pointer "$n"
      onscreen_ok || break
      if (( n == 1 )); then
        gssh systemctl poweroff >/dev/null 2>&1
        stopped_left leftovers-stop "shut down from inside"
        waitfor 30 has_window >/dev/null; sleep 2
        want pointer && gpu_lock_switch
      else
        posted; "$T" close "$QP" >/dev/null
        stopped_left leftovers-close "the VM's window closed (closeAction shutdown)"
      fi
    done
    [[ -z $GONE ]] && quit_left leftovers-quit
  else res window FAIL "the app's window did not open"; shot window-none; fi
else
  log "on-screen rows not run: $GONE"
  want update-vm && update_vm_headless
  want leftovers && headless_leftovers
fi
# Rows that did not get to run on screen.
for r in $ALL; do
  want "$r" || continue
  cut -f2 "$S" | grep -q -E "^$r(-[a-z0-9-]+)?\$" || res "$r" BLOCKED "not run on screen: ${GONE:-an earlier step failed}"
done
cleanup; trap - EXIT
[[ $(feature gpu-compute) == "$GC0" ]] || res switch-stopped-back FAIL "WebGPU and GPU compute is $(feature gpu-compute), was $GC0"
os_result_json "$S" omacvm-e2e-onscreen "$OUT/result.json" app="$APP" version="$VER" commit="$COMMIT" vm="$VM" \
  macos="$(sw_vers -productVersion)" mac="$(sysctl -n hw.model)" seconds=$(( $(date +%s) - T0 )) only="${ONLY:-all}" \
  onscreen="$([[ -z $GONE ]] && echo yes || echo "no: $GONE")" gpuOffMainLoop0="$GPU0"
cut -f3 "$S" | grep -qx FAIL && exit 1
cut -f3 "$S" | grep -qx BLOCKED && exit 3
exit 0
