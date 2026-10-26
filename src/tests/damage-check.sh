#!/bin/bash
# omacvm check's "Changed parts" line (src/guest/check.sh, damage_line): ok
# when the kernel keeps the compositor's damage itself (Linux 7.4) or OmacVM's
# driver with the fix runs; with "Draw only what changed" on (the start asked:
# omacvm.damage=1), a built driver that did not load, or no build with the fix,
# warns; with it off that is a skip. The function is taken from check.sh as it is.
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
expect() {   # what, build's damage file, loader word, asked (1/0), want status, want text in the detail
  local got; got=$(damage_line "$2" "$3" "$4")
  if [[ ${got%%$'\t'*} == "$5" && $got == *"$6"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$5' with '$6'"; fail=1; fi
}
expect "asked, ours, loaded at 8 bits: ok" ours "omacvm 8-bit" 1 ok "OmacVM's driver"
expect "HDR + pointer layer (ours, with the fix), not asked: ok" ours "omacvm cursor_plane=1" 0 ok "what changed"
expect "the kernel's own fix, stock driver, not asked: ok" kernel "stock not asked for this start" 0 ok "kernel keeps"
expect "the kernel's own fix, asked: ok" kernel "stock not needed: the kernel keeps the damage itself" 1 ok "kernel keeps"
expect "asked, ours built, stock runs: warn with the loader's word" ours "stock insmod failed: x" 1 warn "stock insmod failed: x"
expect "asked, ours built, no word from the loader: warn" ours "" 1 warn "no word from omacvm-virtio-gpu-load"
expect "switch off, ours built, stock runs: skip (as asked), no warning" ours "stock not asked for this start" 0 skip "Draw only what changed is off"
expect "switch off, no build: skip" "" "stock not built for 7.2.11-1" 0 skip "Draw only what changed is off"
expect "asked, no build: warn, --status says why" "" "stock not built for 7.2.11-1" 1 warn "--status"
expect "asked, the build left the fix out: warn" "" "omacvm cursor_plane=1 without damage_clips" 1 warn "goes to the Mac whole"
expect "asked, the build could not tell (unknown): warn" unknown "stock built without damage_clips for 7.2.11-1" 1 warn "goes to the Mac whole"
grep -q '"Changed parts"' "$check" || { echo "FAIL: check.sh has no \"Changed parts\" line"; fail=1; }
(( fail == 0 )) && echo "damage-check: all passed"
exit $fail
