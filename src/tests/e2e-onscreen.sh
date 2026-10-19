#!/bin/bash
# The on-screen release test's parts that need no screen, VM or app
# (src/tests/e2e/onscreen.sh): its checks with made-up values, its tool
# compiles, and the harness refuses what is not a test build or a test VM.
#   src/tests/e2e-onscreen.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/tests/e2e/onscreen-lib.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
is() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
isnt() { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }
same() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }

# Nobody at the Mac: idle over 300 s, or the last input was ours.
is "away: idle 400 s" os_away 400 0 No 0 1000
isnt "away: idle 20 s, never posted" os_away 20 0 No 0 1000
is "away: idle 3 s, our event 4 s ago" os_away 3 0 No 996 1000
isnt "away: idle 3 s, our event 60 s ago" os_away 3 0 No 940 1000
isnt "away: a Jump Desktop session" os_away 900 2 No 0 1000
isnt "away: screen locked" os_away 900 0 Yes 0 1000

# The app's window on a 2560x1364 visible frame below a 31 pt menu bar.
V="0 31 2560 1364"
same "window: 800x800 centred" "" "$(os_window_problems "880 313 800 800" "$V")"
same "window: fractions are whole points" "" "$(os_window_problems "880.4 313.2 800.3 799.6" "$V")"
# 3.1.24 opened as tall as the display (#458), and macOS's Fill made it as wide (#452).
p=$(os_window_problems "880 47 800 1332" "$V"); [[ $p == *"1332 pt tall"* ]] && ok "window: too tall ($p)" || bad "window: too tall: '$p'"
p=$(os_window_problems "0 31 2560 1364" "$V"); [[ $p == *"2560 pt wide"* ]] && ok "window: too wide ($p)" || bad "window: too wide: '$p'"
p=$(os_window_problems "100 313 800 800" "$V"); [[ $p == *"not centred across"* ]] && ok "window: off centre" || bad "window: off centre: '$p'"
p=$(os_window_problems "880 600 800 800" "$V"); [[ $p == *"up and down"* && $p == *"visible frame"* ]] && ok "window: low, partly off the display" || bad "window: low: '$p'"
p=$(os_window_problems "880 313 800 460" "$V"); [[ $p == *"less than 500"* ]] && ok "window: too short" || bad "window: too short: '$p'"

is "same size: within 1 pt" os_same_size "10 20 1140 672" "12 40 1140.6 671.5"
isnt "same size: 20 pt smaller (#452)" os_same_size "10 20 1140 672" "10 20 1140 652"

is "cursor: hidden" os_cursor_hidden "visible=0 empty=0 at 10,10"
is "cursor: an empty image" os_cursor_hidden "visible=1 empty=1 at 10,10"
isnt "cursor: the arrow" os_cursor_hidden "visible=1 empty=0 at 10,10"
isnt "cursor: shown, image unknown" os_cursor_hidden "visible=1 empty=? at 10,10"

# What runs on after the run: QEMU of the VM, the app (not its helpers), anything on the VM's folder
# (not another VM's with a longer name).
A="/x/OmacVM Test.app"; D="/v/OmacVM M-e2e"
got=$(os_leftovers "$A" "$D" "OmacVM M-e2e" <<EOF
  101 $A/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e -machine virt
  102 /y/Other.app/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e2 -machine virt
  108 /y/Other.app/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e
  109 /bin/ls /v/OmacVM M-e2e2/logs
  103 $A/Contents/MacOS/OmacVM --vm OmacVM M-e2e
  104 $A/Contents/Helpers/OmacVM Test Bridge.app/Contents/MacOS/omacvm-bridge
  105 /usr/bin/ssh -p 2222 root@127.0.0.1 -o UserKnownHostsFile=$D/known_hosts
  106 /Applications/OmacVM.app/Contents/MacOS/OmacVM-VM -name Omarchy
  107 /bin/bash $A/Contents/Resources/scripts/update-vm.sh $D
EOF
)
same "leftovers: QEMU, the app, a tool on the VM's folder" "101 108 103 105 107" "$(echo "$got" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"

# result.json: pass needs an ok and no FAIL or BLOCKED.
printf '10:00:00\twindow\tok\tframe\n10:00:01\tpointer-1\tFAIL\tarrow\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" version=3.1.24 seconds=12 >/dev/null
same "result: a FAIL does not pass" "False 1 12 3.1.24" "$(/usr/bin/python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); print(o["pass"], o["counts"]["FAIL"], o["seconds"], o["version"])' "$T/r.json")"
printf '10:00:00\twindow\tok\tframe\n10:00:01\tpointer\tBLOCKED\tsomeone\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" >/dev/null
same "result: BLOCKED does not pass" False "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pass"])' "$T/r.json")"
printf '10:00:00\twindow\tok\tframe\n10:00:01\twindow-title-click\tskip\tNone\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" >/dev/null
same "result: ok and skip pass" True "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pass"])' "$T/r.json")"

# The tool compiles (it runs only on a test Mac).
if xcrun swiftc -O "$R/src/tests/e2e/onscreen-tool.swift" -o "$T/onscreen-tool" 2>"$T/swiftc.log"; then
  out=$("$T/onscreen-tool" nonsense 2>&1); [[ $? == 2 && $out == usage* ]] && ok "tool: builds, usage on a wrong command" || bad "tool: '$out'"
else bad "tool does not build: $(head -5 "$T/swiftc.log")"; fi

# The harness refuses a release build and a VM outside the test app's VMs folder (exit 2, nothing started).
H=$R/src/tests/e2e/onscreen.sh
mkdir -p "$T/Rel.app/Contents" "$T/Test.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app" "$T/Rel.app/Contents/Info.plist" >/dev/null
DOM=org.omacvm.app.test.e2e-onscreen.$$
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $DOM" "$T/Test.app/Contents/Info.plist" >/dev/null
trap 'defaults delete "$DOM" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$DOM.plist"' EXIT
out=$("$H" --app "$T/Rel.app" --vm "OmacVM M-e2e" --out "$T/o1" 2>&1); rc=$?
[[ $rc == 2 && $out == *"not a test identity build"* ]] && ok "harness: refuses a release build" || bad "harness: release build: rc $rc '$out'"
defaults write "$DOM" vmsRoot "$T/vms"; mkdir -p "$T/vms"
out=$("$H" --app "$T/Test.app" --vm "OmacVM M-none" --out "$T/o2" 2>&1); rc=$?
[[ $rc == 2 && $out == *"no test VM"* ]] && ok "harness: refuses a VM not in the test VMs folder" || bad "harness: missing VM: rc $rc '$out'"
out=$("$H" --app "$T/Test.app" --vm x --only pointer,nonsense 2>&1); rc=$?
[[ $rc == 2 && $out == *"no row nonsense"* ]] && ok "harness: refuses an unknown row" || bad "harness: unknown row: rc $rc '$out'"

exit $fail
