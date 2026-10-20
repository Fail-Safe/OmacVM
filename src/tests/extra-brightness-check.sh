#!/bin/bash
# omacvm check's extra brightness line (src/cmd/check.sh, ADR 0050) on made-up
# qemu.logs: QEMU's last line wins, else the app's line from the start;
# nothing when the switch is off. The block is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../cmd/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-xb-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^# Extra brightness \(experimental/ {on=1} on {print} on && /^fi$/ {exit}' "$check" > "$T/block.sh"
[[ -s $T/block.sh ]] || { echo "FAIL: no extra brightness block in check.sh"; exit 1; }
fail=0
read_line() {   # log file -> what check prints
  (
    ok() { echo "ok   | $1 | $2"; }
    warn() { echo "warn | $1 | $2"; }
    skip() { echo "skip | $1 | $2"; }
    TYPE=app miclog=$1
    # shellcheck disable=SC1091
    source "$T/block.sh"
  )
}
expect() {   # what, want (a prefix of the line, or "" for none), log lines...
  local what=$1 want=$2 got; shift 2
  printf '%s\n' "$@" > "$T/qemu.log"
  got=$(read_line "$T/qemu.log")
  if [[ -z $want && -z $got ]] || [[ -n $want && $got == "$want"* ]]; then echo "ok   $what"
  else echo "FAIL $what: got '$got', want '$want'"; fail=1; fi
}
p="qemu-system-aarch64: "
expect "on" "ok   | Extra brightness | on (2.00x now" \
  "OmacVM: extra brightness: on (up to 2x on a display with the headroom)" "${p}cocoa: extra brightness: on, 2.00x"
expect "held back: still ok, says why" "ok   | Extra brightness | on, held back by macOS to 1.40x" \
  "${p}cocoa: extra brightness: on, 2.00x" "${p}cocoa: extra brightness: held back by macOS, 1.40x"
expect "not on this display" "skip | Extra brightness | the VM window's display has no extra brightness" \
  "OmacVM: extra brightness: off (no display with extra brightness)" "${p}cocoa: extra brightness: not on this display (EDR potential 2.00)"
expect "GPU safe mode (QEMU's line)" "warn | Extra brightness | extra brightness is on, but this run has none (frames in a CAOpenGLLayer" \
  "OmacVM: extra brightness: off (GPU safe mode)" "${p}cocoa: extra brightness: off (frames in a CAOpenGLLayer: GPU safe mode or OMACVM_GL_PRESENT=layer)"
expect "GPU safe mode (only the app's line)" "warn | Extra brightness | extra brightness is on, but this run has none (GPU safe mode)" \
  "OmacVM: extra brightness: off (GPU safe mode)"
expect "HDR" "skip | Extra brightness | off while the VM shows HDR" "${p}cocoa: extra brightness: not with HDR yet (the guest sends PQ)"
expect "turned off while it ran: nothing" "" "${p}cocoa: extra brightness: on, 2.00x" "${p}cocoa: extra brightness: off (switch off)"
expect "switch off: nothing" "" "${p}cocoa: GL frames shown as IOSurfaces"
expect "the test hook's line is no state" "ok   | Extra brightness | on (2.00x now" \
  "${p}cocoa: extra brightness: on, 2.00x" "${p}cocoa: extra brightness: display from OMACVM_TEST_EDR (potential 16.00, headroom 2.40)"
(( fail == 0 )) && echo "extra-brightness-check: all passed"
exit $fail
