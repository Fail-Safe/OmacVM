#!/bin/bash
# Another program's arguments that are not UTF-8 (#545). omacvm runs in a
# UTF-8 locale (src/lib/ui.sh), where macOS's awk stops at such a line
# ("illegal byte sequence"), and pgrep -f and pkill -f fail outright. A running
# VM was then taken as stopped: a control centre switch tried to start it ("did
# not get an address"). Stand-ins only: a process with the bytes the e2e
# harness had in ssh's arguments (bash 3.2's printf %q of "…": E2 '\200' A6),
# started before a stand-in QEMU, Bridge and build. No VM, no app.
#   src/tests/ps-not-utf8.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT INT TERM
fail=0
check() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
export LC_ALL=en_US.UTF-8 HOME=$T/home
mkdir -p "$HOME"

BAD=$'toggle Mac input: Chinese, Japanese\xe2\\200\xa6 on 900 '"$T"
perl -e 'sleep 120' -- "$BAD" & B=$!; PIDS+=" $B"
sleep 0.2
check "the line is not UTF-8" no "$(ps -p "$B" -o args= | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo yes || echo no)"

# 1. app_pid_dir: the stand-in QEMU is listed after that line (a higher pid).
D=$T/VMs/Work
mkdir -p "$D"; : > "$D/disk.img"
source "$R/src/lib/app.sh"
listed_after() {   # PID: ps lists it after the line that is not UTF-8
  ps -x -U "$(id -u)" -o pid= | awk -v b="$B" -v q="$1" '$1 == b { s = 1 } $1 == q { print (s ? "yes" : "no"); exit }'
}
for _ in 1 2 3; do   # pids wrap around once in a long while
  perl -e 'sleep 120' -- -name "OmacVM Work" -drive "if=none,id=disk,file=$D/disk.img,format=raw" & Q=$!; PIDS+=" $Q"
  sleep 0.2
  [[ $(listed_after "$Q") == yes ]] && break
  kill "$Q"
done
check "the stand-in QEMU is listed after it" yes "$(listed_after "$Q")"
check "app_pid_dir finds the running VM" "$Q" "$(app_pid_dir "$D" 2>&1)"
check "the VM counts as running" yes "$(app_running_dir "$D" 2>/dev/null && echo yes || echo no)"
kill "$Q"; wait "$Q" 2>/dev/null
check "stopped once its QEMU is gone" "" "$(app_pid_dir "$D" 2>/dev/null)"

# 2. helper_pid: a stand-in test Bridge (pgrep -f). Another one of this Mac
# may be older (-o): any pid with that command line will do.
source "$R/src/lib/mac.sh"
bash -c 'exec -a "$1" sleep 120' _ "$T/OmacVM Test Bridge.app/Contents/MacOS/omacvm-test-bridge" & H=$!; PIDS+=" $H"
sleep 0.2
h=$(helper_pid bridge test 2>&1)
a=""; [[ $h =~ ^[0-9]+$ ]] && a=$(ps -p "$h" -o args=)
check "helper_pid finds a running Bridge" yes "$([[ $a == *"OmacVM Test Bridge.app/Contents/MacOS/"* ]] && echo yes || echo "no: '$h'")"
kill "$H"

# 3. others_building (app/scripts/vm-common.sh): another build, only this run's
# stand-ins seen (named under $T). Here the line that is not UTF-8 is a bash
# one too: the pattern of a build reads it to its end.
(exec -a "/bin/bash $T/notes/$BAD" sleep 120) & B2=$!; PIDS+=" $B2"
eval "$(sed -n '/^others_building()/,/^}/p' "$R/app/scripts/vm-common.sh")"
ps() {
  if [[ $* == *args=* ]]; then command ps "$@" | LC_ALL=C awk -v t="$T/" 'index($0, t)'; else command ps "$@"; fi
}
other=$(T=$T /bin/bash -c '(exec -a "/bin/bash $T/x/create-vm.sh $T/y/Omarchy" sleep 120) >/dev/null 2>&1 & echo $!')
PIDS+=" $other"; sleep 0.2
check "others_building sees another build" 0 "$(others_building 2>/dev/null; echo $?)"
kill "$other"
unset -f ps

# 4. The e2e harness's cc(): what goes to ssh stays UTF-8 and means the same
# in the VM's shell.
OUT=$T PFX=""
gssh() { printf '%s' "$1" > "$T/cc-line"; }
eval "$(sed -n '/^cc() {/,/^}/p' "$R/src/tests/e2e/cc-switches.sh")"
cc toggle "Mac input: Chinese, Japanese…" "it's \"x\" \$HOME \\" on 900 >/dev/null 2>&1
check "cc: ssh's line is UTF-8" yes "$(iconv -f UTF-8 -t UTF-8 < "$T/cc-line" >/dev/null 2>&1 && echo yes || echo no)"
check "cc: the same arguments in the VM's shell" "[toggle][Mac input: Chinese, Japanese…][it's \"x\" \$HOME \\][on][900]" \
  "$(/bin/bash -c "printf '[%s]' $(sed 's/^python3 [^ ]*//' "$T/cc-line")")"

exit $fail
