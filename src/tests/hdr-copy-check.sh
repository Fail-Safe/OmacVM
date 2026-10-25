#!/bin/bash
# omacvm check's HDR line, its part about Hyprland's SDR copy (src/guest/check.sh,
# hdr_copy_note): 0 (omacvm_app.lua) = a copy only while something captures; 1 = a
# copy of every frame; 2 or no answer (an older Hyprland) = Hyprland's own default,
# which makes no copy while the SDR white is Hyprland's own. The function is taken
# from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-copy.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^hdr_copy_note\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no hdr_copy_note in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, hyprctl's answer, want
  local got; got=$(hdr_copy_note "$2")
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
expect "0: only while capturing" "int: 0" "; SDR copy only while capturing"
expect "0 with hyprctl's set line" $'int: 0\nset: true' "; SDR copy only while capturing"
expect "1: every frame" "int: 1" "; an SDR copy of every frame (render:keep_unmodified_copy 1)"
expect "2: Hyprland's default" "int: 2" "; SDR copy: Hyprland's default"
expect "no answer (older Hyprland): Hyprland's default, no '?'" "" "; SDR copy: Hyprland's default"
expect "an error text: Hyprland's default" "no such option" "; SDR copy: Hyprland's default"
(( fail == 0 )) && echo "hdr-copy-check: all passed"
exit $fail
