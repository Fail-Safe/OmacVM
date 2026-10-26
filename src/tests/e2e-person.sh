#!/bin/bash
# The e2e harnesses' "someone at the Mac" checks (src/tests/e2e/person.sh) and
# the CI runner pause (src/tests/e2e/ci-runners.sh), with made-up sources: a
# fake remote session (Screen Sharing, port 5900, Jump Desktop), a fake HID
# idle time, fake launchctl and pgrep. No screen, VM or runner needed.
#   src/tests/e2e-person.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
WATCHERS=()
trap 'for p in ${WATCHERS[@]+"${WATCHERS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
same() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }
has() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: want '$2' in '$3'"; fi; }

export HOME=$T/home; mkdir -p "$HOME"
unset OMACVM_E2E_IGNORE_IDLE PERSON_DIR PERSON_WATCH_PID
source "$R/src/tests/e2e/person.sh"

# ---- the made-up Mac: files say what its sources report
F=$T/fake; mkdir -p "$F"; : > "$F/pmset"; : > "$F/ps"; : > "$F/tcp"
echo $(( $(date +%s) - 1000 )) > "$F/last-input"
_person_pmset() { cat "$F/pmset"; }
_person_ps() { cat "$F/ps"; }
_person_tcp() { cat "$F/tcp"; }
_person_idle_raw() { echo $(( $(date +%s) - $(cat "$F/last-input") )); }
quiet_mac() { : > "$F/pmset"; : > "$F/ps"; : > "$F/tcp"; }
TAB=$'\t'

# ---- person_verdict: IDLE REMOTE OWN FOREIGN NOW
same "verdict: idle 400 s, nobody" "" "$(person_verdict 400 "" 0 0 10000)"
has "verdict: idle 20 s, never ours" "input 20 s ago, not ours" "$(person_verdict 20 "" 0 0 10000)"
same "verdict: idle 3 s, ours until 2 s ago" "" "$(person_verdict 3 "" 9998 0 10000)"
has "verdict: idle 3 s, ours until 60 s ago" "not ours" "$(person_verdict 3 "" 9940 0 10000)"
has "verdict: a remote session, however long idle" "remote session: jump-desktop" "$(person_verdict 5000 jump-desktop 0 0 10000)"
has "verdict: the watcher saw foreign input 100 s ago, ours after it" "not ours" "$(person_verdict 2 "" 9999 9900 10000)"
same "verdict: the watcher's foreign input 400 s ago" "" "$(person_verdict 400 "" 0 9600 10000)"
same "verdict: OMACVM_E2E_IGNORE_IDLE=1" "" "$(OMACVM_E2E_IGNORE_IDLE=1 person_verdict 1 vnc-5900 0 0 10000)"

# ---- person_remote: each kind of session, and what must not count
same "remote: none" "" "$(person_remote)"
echo '   pid 412(screensharingd): [0x1] 00:00:09 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
same "remote: Screen Sharing's assertion" "screen-sharing" "$(person_remote)"
quiet_mac
echo "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd${TAB}/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd" > "$F/ps"
same "remote: screensharingd runs (no assertion yet)" "screen-sharing" "$(person_remote)"
quiet_mac
# nettop -m tcp -l 1 -L 1 -n, as macOS 27 prints it
printf '18:06:28.587078,tcp4 192.168.1.20:5900<->192.168.1.31:52144,en0,Established,1280195,5739135,0,0,7768,40.59 ms,131072,\n' > "$F/tcp"
same "remote: an established connection on 5900" "vnc-5900" "$(person_remote)"
printf '18:06:28.586544,tcp4 *:5900<->*:*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,\n18:06:28.586492,tcp6 *.5900<->*.*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,\n' > "$F/tcp"
same "remote: 5900 only listening" "" "$(person_remote)"
quiet_mac
echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect${TAB}/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --rtcproxy --port 0" > "$F/ps"
same "remote: Jump Desktop's rtcproxy" "jump-desktop" "$(person_remote)"
echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/desktopproxy${TAB}desktopproxy --session 4" > "$F/ps"
same "remote: Jump Desktop's desktopproxy" "jump-desktop" "$(person_remote)"
{ echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect${TAB}/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --service"
  echo "Core Audio Driver (JumpAudio.driver)${TAB}Core Audio Driver (JumpAudio.driver)"
  echo "/usr/bin/pgrep${TAB}pgrep -f JumpConnect.*(rtcproxy|desktopproxy)"
  echo "/bin/bash${TAB}/bin/bash kit/mini-run.sh screensharingd Jump rtcproxy"; } > "$F/ps"
same "remote: Jump's idle service, its audio driver, a script naming them" "" "$(person_remote)"
quiet_mac
echo '   pid 412(screensharingd): [0x1] 00:00:09 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
printf '18:06:28.594041,tcp6 fe80::1%%en0.5900<->fe80::2%%en0.52144,en0,Established,249\n' > "$F/tcp"
same "remote: two kinds at once" "screen-sharing,vnc-5900" "$(person_remote)"
quiet_mac

# ---- person_posted: our own input hides nothing that came after it
person_posted 5
o=$(cat "$PERSON_OWN"); now=$(date +%s)
(( o >= now + 4 && o <= now + 5 )) && ok "posted: ours until now + 5 s" || bad "posted: '$o' (now $now)"
person_posted 1
same "posted: a shorter window does not shorten a longer one" "$o" "$(cat "$PERSON_OWN")"
echo 0 > "$PERSON_OWN"

# ---- the watcher: a fake HID idle source, foreign input and a remote connect logged with their times
PERSON_TICK=0.2 PERSON_IDLE_MIN=3 PERSON_POLL=0.2
person_watch_start; WATCHERS+=("$PERSON_WATCHER")
[[ -d $PERSON_DIR && -n $PERSON_WATCH_PID ]] && ok "watch: started (shared through PERSON_DIR)" || bad "watch: not started"
sleep 0.6
# Our own input: stamped first, then HID idle drops.
person_posted 3; date +%s > "$F/last-input"; sleep 0.8
same "watch: our own input is not logged" "" "$(cat "$PERSON_DIR/watch.log")"
# Someone's: HID idle drops with no stamp of ours.
echo 0 > "$PERSON_OWN"; echo $(( $(date +%s) - 50 )) > "$F/last-input"; sleep 0.6
date +%s > "$F/last-input"; sleep 0.8
has "watch: foreign input logged" "input" "$(cut -f2 "$PERSON_DIR/watch.log")"
has "watch: ... with its time" "HID input at $(date +%H:%M)" "$(cat "$PERSON_DIR/watch.log")"
printf '18:06:28.1,tcp4 10.0.0.2:5900<->10.0.0.9:50000,en0,Established,1,1\n' > "$F/tcp"; sleep 1.5
has "watch: a Screen Sharing connect logged" "vnc-5900" "$(grep "${TAB}remote${TAB}" "$PERSON_DIR/watch.log")"
quiet_mac; sleep 1
has "watch: ... and its end" "none" "$(grep "${TAB}remote${TAB}" "$PERSON_DIR/watch.log" | tail -1)"

# ---- person_gate: overlap reported once, pause while someone is there, resume when quiet, give up
OVER=""; person_overlap() { OVER="$2: $1"; }
echo $(( $(date +%s) - 100 )) > "$F/last-input"
PERSON_WAIT=10 person_gate row-a > "$T/gate1.txt"; rc=$?
same "gate: quiet again -> goes on" 0 "$rc"
has "gate: the visit since the last gate goes to person_overlap" "row-a: HID input at" "$OVER"
has "gate: ... the connect as well" "vnc-5900" "$OVER"
OVER=""; PERSON_WAIT=10 person_gate row-b > /dev/null
same "gate: the same visit is not reported twice" "" "$OVER"
# A Screen Sharing session opens: the gate pauses, and goes on when it ends.
echo '   pid 412(screensharingd): [0x1] 00:00:01 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
( sleep 1.5; : > "$F/pmset" ) &
t0=$(date +%s); PERSON_WAIT=20 person_gate row-c > "$T/gate2.txt"; rc=$?; t1=$(date +%s)
same "gate: a remote session -> pause, then on when it ends" 0 "$rc"
has "gate: ... PAUSE logged with the reason" "PAUSE before row-c: remote session: screen-sharing" "$(cat "$T/gate2.txt")"
has "gate: ... RESUME logged" "RESUME before row-c" "$(cat "$T/gate2.txt")"
(( t1 - t0 >= 1 )) && ok "gate: ... it waited" || bad "gate: did not wait (${t1}-${t0})"
# Someone types and stays: the gate gives up after PERSON_WAIT.
( for i in 1 2 3 4 5 6 7 8 9 10; do date +%s > "$F/last-input"; sleep 0.3; done ) & typing=$!
sleep 0.3
PERSON_WAIT=2 person_gate row-d > "$T/gate3.txt"; rc=$?
same "gate: someone stays -> gives up" 1 "$rc"
has "gate: ... and says why" "someone at the Mac since" "$PERSON_WHY"
has "gate: ... GIVE UP logged" "GIVE UP before row-d" "$(cat "$T/gate3.txt")"
wait "$typing"
# A harness started by this one (modifier-keys.sh by cc-switches.sh) joins the same watcher.
cat > "$T/child.sh" <<EOF
source "$R/src/tests/e2e/person.sh"
person_watch_start
echo "\$PERSON_DIR \$PERSON_WATCHER"
EOF
same "watch: a child harness uses the caller's watcher" "$PERSON_DIR " "$(bash "$T/child.sh")"
d=$PERSON_DIR; person_watch_stop
[[ ! -d $d ]] && ! kill -0 "${WATCHERS[0]}" 2>/dev/null && ok "watch: stopped, its folder gone" || bad "watch: still there"

# ---- ci-runners.sh with a fake launchctl and pgrep
B=$T/bin; L=$T/loaded; W=$T/busy; A=$T/agents; mkdir -p "$B" "$L" "$W" "$A"
cat > "$B/launchctl" <<EOF
#!/bin/bash
# fake: loaded runners are files in $L
echo "\$*" >> "$T/launchctl.log"
case \$1 in
  print) [[ -e "$L/\${2##*/}" ]] ;;
  bootout) [[ -e "$L/\${2##*/}" ]] && rm -f "$L/\${2##*/}" ;;
  bootstrap) touch "$L/\$(plutil -extract Label raw -o - "\$3")" ;;
esac
EOF
cat > "$B/pgrep" <<EOF
#!/bin/bash
# fake: a runner folder with a job is a file in $W
p=\${@: -1}; d=\${p%/bin/Runner.Worker}; [[ -e "$W/\${d##*/}" ]]
EOF
chmod +x "$B/launchctl" "$B/pgrep"
for n in 1 2; do
  plutil -create xml1 "$A/actions.runner.o-r.mini-$n.plist"
  plutil -insert Label -string "actions.runner.o-r.mini-$n" "$A/actions.runner.o-r.mini-$n.plist"
  plutil -insert WorkingDirectory -string "/x/actions-runner-$n" "$A/actions.runner.o-r.mini-$n.plist"
  touch "$L/actions.runner.o-r.mini-$n"
done
touch "$W/actions-runner-2"   # runner 2 has a job
CR() { PATH=$B:$PATH CI_AGENTS=$A CI_STATE=$T/ci-state "$R/src/tests/e2e/ci-runners.sh" "$@"; }
CR pause --wait 0 --holder $$ > "$T/ci1.txt"; rc=$?
same "ci: a runner on a job is not stopped (exit 4 after --wait)" 4 "$rc"
[[ ! -e $L/actions.runner.o-r.mini-1 && -e $L/actions.runner.o-r.mini-2 ]] && ok "ci: the idle runner stopped, the busy one kept" || bad "ci: $(ls "$L" | tr '\n' ' ')"
rm -f "$W/actions-runner-2"
CR pause --wait 30 --holder $$ > "$T/ci2.txt"; rc=$?
same "ci: its job over -> stopped too" 0 "$rc"
same "ci: no runner runs" "" "$(ls "$L")"
same "ci: both written down" 2 "$(wc -l < "$T/ci-state/stopped" | tr -d ' ')"
sleep 60 & other=$!
CR pause --wait 0 --holder $other > /dev/null
CR resume --holder $$ > "$T/ci3.txt"
same "ci: another gate still holds the pause: nothing started" "" "$(ls "$L")"
has "ci: ... and says so" "other holder" "$(cat "$T/ci3.txt")"
kill $other; wait $other 2>/dev/null
CR resume --holder 999999 > "$T/ci4.txt"; rc=$?
same "ci: the last holder gone -> resume starts both" "actions.runner.o-r.mini-1 actions.runner.o-r.mini-2" "$(ls "$L" | tr '\n' ' ' | sed 's/ $//')"
same "ci: ... exit 0, state gone" "0 gone" "$rc $([[ -e $T/ci-state ]] && echo there || echo gone)"
CR resume > /dev/null; rc=$?
same "ci: resume with nothing paused does nothing" "0" "$rc"
has "ci: status lists the runners" "actions.runner.o-r.mini-1	running	idle" "$(CR status)"

# ---- the harnesses ask between rows, not only at their start (3.2.4: two Screen Sharing connects
# inside a run that looked only at its start)
E=$R/src/tests/e2e
wired() {   # NAME FILE PATTERN...: every pattern in the file
  local n=$1 f=$2 p; shift 2
  for p in "$@"; do grep -qE -- "$p" "$f" || { bad "wiring: $n: no /$p/"; return; }; done
  ok "wiring: $n"
}
wired "cc-switches waits before its first row and before each step" "$E/cc-switches.sh" \
  '^source "\$HERE/person.sh"' '^person_gate start' 'person_watch_start' 'gate "switch-\$n"' '    gate "\$st"' \
  '\{ gate keys; step_keys; \}' '\{ gate window; step_window; \}' '\{ gate unplug; step_unplug; \}' '^  gate update' '^    gate prepare'
wired "cc-switches: a visit's row, the watcher stopped, CI runners back" "$E/cc-switches.sh" \
  'person_overlap "\$ev" end' 'person_watch_stop' 'ci-runners.sh" resume --holder \$\$' 'ci-runners.sh" pause --wait'
# No question to the Mac's state left that looks only once (the old start-only checks).
if grep -nE 'HIDIdleTime|screensharingd|JumpConnect' "$E/cc-switches.sh" "$E/modifier-keys.sh" "$E/display-unplug.sh"; then
  bad "wiring: a harness asks HID idle or remote sessions itself (person.sh does)"
else ok "wiring: HID idle and remote sessions only through person.sh"; fi
wired "modifier-keys waits before each case and stamps its own events" "$E/modifier-keys.sh" \
  '^source "\$HERE/person.sh"' 'person_gate "keys-\$name"' 'person_posted 3; "\$KS" --pid "\$PID" \$evs; person_posted' 'exit 3'
wired "display-unplug waits before each case" "$E/display-unplug.sh" \
  '^source "\$HERE/person.sh"' 'gate full && case_run' 'gate fullpanel && case_run' 'gate window && case_run' '&& gate head; then'

exit $fail
