#!/bin/bash
# The checks of src/tests/e2e/onscreen.sh that need no Mac screen, VM or app:
# CI runs them with made-up values (src/tests/e2e-onscreen.sh). Source it.
#   os_away IDLE JUMP LOCKED LAST NOW     exit 0 when nobody uses the Mac: no Jump Desktop session
#                                         (JUMP: its proxies), the screen not locked (LOCKED: Yes|No),
#                                         and no input for 300 s but our own (LAST: when we last
#                                         posted an event, epoch s, 0 for never; IDLE: HID idle, s)
#   os_window_problems "X Y W H" "SX SY SW SH"
#                                         what is wrong with the app's window on its display's visible
#                                         frame (points, top left): 800 wide, 500-800 tall, centred;
#                                         nothing printed when it is right
#   os_same_size "X Y W H" "X Y W H"      exit 0 when both are as wide and as tall (within 1 pt)
#   os_cursor_hidden "visible=V empty=E at X,Y"
#                                         exit 0 when the Mac shows no cursor: hidden, or an empty image
#   os_leftovers APP VMDIR VMNAME         reads "PID ARGS" lines (ps -axww -o pid=,args=) and prints
#                                         those of the run: QEMU of VMNAME, anything run from APP
#                                         (not its Helpers: Bridge and Gestures stay), anything on VMDIR
#   os_result_json SUMMARY KIND JSON KEY=VALUE...
#                                         result.json from summary.tsv (time, row, ok|FAIL|BLOCKED|skip,
#                                         what): pass = no FAIL, no BLOCKED, at least one ok
OS_WIDTH=800 OS_MIN_H=500 OS_MAX_H=800

os_away() {
  local idle=$1 jump=$2 locked=$3 last=$4 now=$5
  (( jump == 0 )) || return 1
  [[ $locked != Yes ]] || return 1
  (( idle > 300 )) && return 0
  # The last input was ours: it came no later than our last event (2 s slack).
  (( last > 0 && now - idle <= last + 2 ))
}

# Rounded to whole points (AX gives fractions after a resize).
_os_int() { printf '%.0f' "$1"; }

os_window_problems() {
  local x y w h sx sy sw sh dx dy
  read -r x y w h <<<"$1"; read -r sx sy sw sh <<<"$2"
  x=$(_os_int "$x"); y=$(_os_int "$y"); w=$(_os_int "$w"); h=$(_os_int "$h")
  sx=$(_os_int "$sx"); sy=$(_os_int "$sy"); sw=$(_os_int "$sw"); sh=$(_os_int "$sh")
  (( w >= OS_WIDTH - 1 && w <= OS_WIDTH + 1 )) || echo "${w} pt wide, not ${OS_WIDTH}"
  (( h <= OS_MAX_H + 1 )) || echo "${h} pt tall, more than ${OS_MAX_H}"
  (( h >= OS_MIN_H - 1 )) || echo "${h} pt tall, less than ${OS_MIN_H}"
  # Centred on the visible frame: both middles within 2 pt.
  dx=$(( (2 * x + w) - (2 * sx + sw) )); dy=$(( (2 * y + h) - (2 * sy + sh) ))
  (( dx >= -4 && dx <= 4 )) || echo "not centred across: middle $(( x + w / 2 )), the display's $(( sx + sw / 2 ))"
  (( dy >= -4 && dy <= 4 )) || echo "not centred up and down: middle $(( y + h / 2 )), the display's $(( sy + sh / 2 ))"
  (( x >= sx && y >= sy && x + w <= sx + sw && y + h <= sy + sh )) || echo "not inside the display's visible frame"
  return 0
}

os_same_size() {
  local a b w1 h1 w2 h2
  read -r _ _ a b <<<"$1"; w1=$(_os_int "$a"); h1=$(_os_int "$b")
  read -r _ _ a b <<<"$2"; w2=$(_os_int "$a"); h2=$(_os_int "$b")
  (( w1 - w2 <= 1 && w2 - w1 <= 1 && h1 - h2 <= 1 && h2 - h1 <= 1 ))
}

os_cursor_hidden() {
  [[ $1 == visible=0* || $1 == *" empty=1 "* ]]
}

os_leftovers() {
  local app=$1 vmd=$2 vm=$3
  awk -v app="$app/" -v helpers="$app/Contents/Helpers/" -v vmd="$vmd" -v q=" -name $vm" -v me="$$" '
    # S in A, followed by the end, a space or a slash (so "M-e2e" is not "M-e2e2")
    function has(a, s,   i, c) {
      while ((i = index(a, s)) > 0) {
        c = substr(a, i + length(s), 1)
        if (c == "" || c == " " || c == "/") return 1
        a = substr(a, i + 1)
      }
      return 0
    }
    { pid = $1; a = $0; sub(/^ *[0-9]+ +/, "", a) }
    pid == me { next }
    has(a, q) { print; next }
    index(a, app) == 1 && index(a, helpers) != 1 { print; next }
    has(a, vmd) && a !~ /^(\/usr\/bin\/|\/bin\/)?(ps|awk|grep|pgrep|tail|cat|less) / { print; next }'
}

os_result_json() {
  local summary=$1 kind=$2 json=$3; shift 3
  /usr/bin/python3 - "$summary" "$kind" "$json" "$@" <<'PY'
import json, sys
summary, kind, out, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
rows, counts = [], {}
for line in open(summary, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 4:
        continue
    rows.append({"time": f[0], "row": f[1], "result": f[2], "what": f[3]})
    counts[f[2]] = counts.get(f[2], 0) + 1
o = {"kind": kind, "counts": counts, "rows": rows,
     "pass": counts.get("ok", 0) > 0 and not counts.get("FAIL") and not counts.get("BLOCKED")}
for kv in extra:
    k, _, v = kv.partition("=")
    o[k] = int(v) if v.isdigit() else v
json.dump(o, open(out, "w"), indent=1)
print("pass" if o["pass"] else "NOT passed", counts)
PY
}
