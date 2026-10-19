#!/bin/bash
# OmacVM.app's hyprpicker patch (src/app/guest/hyprpicker/) on hyprpicker's
# release: it applies, and a buffer file gets no lasting name in
# XDG_RUNTIME_DIR. The patched build stops on SIGTERM with _Exit, which skips
# the destructors that deleted the files; up to 3.1.24 each screenshot left
# them there until that tmpfs was full and Hyprland died of SIGBUS.
# Needs github.com (skips without it).
#   src/tests/hyprpicker-patch.sh [TAG]   (default: the release the VMs have)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/src/app/guest/hyprpicker/redraw-on-change.patch
TAG=${1:-v0.4.7}
fail=0
expect() {   # WHAT CONDITION...
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
if ! git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" \
     https://github.com/hyprwm/hyprpicker "$T/src" 2>/dev/null; then
  echo "skip: cannot download hyprpicker $TAG"; exit 0
fi
cd "$T/src" || exit 1
expect "the patch applies to hyprpicker $TAG" git apply --check "$P"
git apply "$P" 2>/dev/null || exit 1

# createPoolFile's body, from mkstemp to the return
body=$(awk '/^int CHyprpicker::createPoolFile/ { f = 1 } f { print } f && /^}/ { exit }' src/hyprpicker.cpp)
after=$(printf '%s\n' "$body" | sed -n '/mkstemp(/,$p')
first=$(printf '%s\n' "$after" | grep -m1 -o -E 'unlink\(name\.c_str\(\)\)|setCloexec|ftruncate|return FD')
expect "the file's name goes right after mkstemp, before anything else can stop hyprpicker" \
  test "$first" = 'unlink(name.c_str())'
expect "the name is cleared (the destructor's unlink cannot hit another file)" \
  grep -q 'name.clear();' <<<"$after"
expect "the buffers are made only through createPoolFile" \
  test "$(grep -rl 'hyprpicker_XXXXXX' src | wc -l | tr -d ' ')" = 1
exit $fail
