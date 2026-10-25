#!/bin/bash
# omacvm check's "Frames in step" line (src/guest/check.sh, vsync_lock_line):
# ok only when the driver's kernel log says its vblanks were in step with the
# Mac's refresh in this start; the loader's word alone (the option is on) is
# not enough: QEMU may not answer (GPU safe mode's 2D display), the rates may
# differ, or no frames moved yet. A build without the vsync lock warns. The
# function is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vsync-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^vsync_lock_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no vsync_lock_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, loader word, kernel log line, want status, want text in the detail
  local got; got=$(vsync_lock_line "$2" "$3")
  if [[ ${got%%$'\t'*} == "$4" && $got == *"$5"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$4' with '$5'"; fail=1; fi
}
L="[drm] vsync_lock:"
expect "in step: ok" "omacvm 8-bit vsync_lock=1" "$L in step with the host's refresh" ok "were in step"
expect "HDR + pointer layer, in step: ok" "omacvm cursor_plane=1 vsync_lock=1" "$L in step with the host's refresh" ok "in this start"
expect "loaded, nothing in step yet: not ok" "omacvm 8-bit vsync_lock=1" "" skip "not in step yet"
expect "QEMU does not know the command: warn" "omacvm 8-bit vsync_lock=1" "$L the host does not know it, the vblank timer runs on its own" warn "does not answer"
expect "rates differ: not ok" "omacvm 8-bit vsync_lock=1" "$L the host's refresh (8333 us) is not the mode's (16666 us), the vblank timer runs on its own" skip "not the VM's display rate"
expect "the build has no vsync lock: warn" "omacvm cursor_plane=1 without vsync_lock" "" warn "has no vsync lock"
expect "stock driver: warn with the loader's reason" "stock not built for 7.3.0" "" warn "the stock driver runs: not built for 7.3.0"
expect "no word from the loader: warn" "" "" warn "no word from omacvm-virtio-gpu-load"
(( fail == 0 )) && echo "vsync-lock-check: all passed"
exit $fail
