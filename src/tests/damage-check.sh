#!/bin/bash
# omacvm check's "Changed parts" line (src/guest/check.sh, damage_line): ok
# when the kernel keeps the compositor's damage itself (Linux 7.4) or OmacVM's
# driver with the fix runs; a built driver that did not load warns; no build
# (or one that left the fix out) is a skip. The function is taken from
# check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-damage-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^damage_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no damage_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, build's damage file, loader word, want status, want text in the detail
  local got; got=$(damage_line "$2" "$3")
  if [[ ${got%%$'\t'*} == "$4" && $got == *"$5"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$4' with '$5'"; fail=1; fi
}
expect "ours, loaded at 8 bits: ok" ours "omacvm 8-bit" ok "OmacVM's driver"
expect "ours, HDR + pointer layer: ok" ours "omacvm cursor_plane=1" ok "what changed"
expect "the kernel's own fix, stock driver: ok" kernel "stock not asked for this start" ok "kernel keeps"
expect "ours built, stock runs: warn with the loader's word" ours "stock insmod failed: x" warn "stock insmod failed: x"
expect "ours built, no word from the loader: warn" ours "" warn "no word from omacvm-virtio-gpu-load"
expect "no build: skip" "" "stock not built for 7.2.11-1" skip "--status"
expect "the build left the fix out: skip" "" "omacvm cursor_plane=1" skip "every frame whole"
grep -q '"Changed parts"' "$check" || { echo "FAIL: check.sh has no \"Changed parts\" line"; fail=1; }
(( fail == 0 )) && echo "damage-check: all passed"
exit $fail
