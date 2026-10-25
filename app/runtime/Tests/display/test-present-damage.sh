#!/bin/bash
# Partial present (omacvm-cocoa-present-damage*.patch):
#   - the rules: the logic patch makes ui/omacvm-present-damage.h in an empty
#     folder and test-present-damage.c runs against it (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (the guest's flush rects go in, the
#     present draws a surface's box scissored and without the clear, full
#     draws on the listed changes, OMACVM_GL_PRESENT_DAMAGE=0 and =check);
#   - with --self-test (CI): the wiring checks fail on the code without it.
#   test-present-damage.sh [<patched ui/cocoa.m> | --self-test]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 present flush alloc
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  flush=$(body "$m" 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,')
  alloc=$(body "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)')
  [[ -n $present && -n $flush && -n $alloc ]] || { echo "no cocoa_gl_present, scanout_flush or present_alloc"; return; }
  grep -q '#include "ui/omacvm-present-damage.h"' "$m" || echo "the rules are not included"
  grep -q 'omacvm_pd_add(&present_pd, x, y, w, h);' <<<"$flush" || echo "the guest's flush rects are not collected"
  grep -q 'omacvm_pd_reset(&present_pd, present_nsurf,' <<<"$alloc" || echo "new surfaces are not drawn in full"
  grep -q 'omacvm_pd_take(&present_pd, n, &pd)' <<<"$present" || echo "the present does not ask what surface n needs"
  grep -q 'omacvm_pd_frame(&present_pd, w, h);' <<<"$present" || echo "another frame size does not draw in full"
  grep -q 'omacvm_pd_all_full(&present_pd);' <<<"$present" || echo "a change of path or buffer does not draw in full"
  grep -q 'glScissor(pd.x, pd.y, pd.w, pd.h);' <<<"$present" || echo "the box is not scissored"
  # The clear only on full draws: it sits in the else branch of the partial one.
  awk '/glScissor\(pd.x, pd.y, pd.w, pd.h\);/{s=NR} /} else {/{if (s && !e) e=NR} /glClear\(GL_COLOR_BUFFER_BIT\);/{if (e && !c) c=NR}
       END{exit !(s && e && c && s < e && e < c)}' <<<"$present" || echo "a partial draw clears the surface"
  for want in '!splash' '!boost' 'gl_scanout_borrow &&' 'w == present_w && h == present_h' 'gl_scanout_x == 0 && gl_scanout_y == 0'; do
    grep -qF "$want" <<<"$present" || echo "partial draws are not limited by: $want"
  done
  grep -q 'getenv("OMACVM_GL_PRESENT_DAMAGE")' <<<"$present" || echo "OMACVM_GL_PRESENT_DAMAGE is not read"
  grep -q 'cocoa_gl_present_pd_check(src, flip, n, pd);' <<<"$present" || echo "the check mode is not wired"
  grep -q 'glDisable(GL_SCISSOR_TEST);' <<<"$present" || echo "the scissor is left on"
}
if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-damage.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  { printf 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)\n{\n}\n'
    printf 'static bool cocoa_gl_present(void)\n{\n    glClear(GL_COLOR_BUFFER_BIT);\n}\n'
    printf 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,\n{\n    gl_dirty = true;\n}\n'; } > "$T/old.m"
  if [[ -n $(problems "$T/old.m") ]]; then echo "ok   the wiring checks fail on the code without the patch"; exit 0; fi
  echo "FAIL the wiring checks pass on the code without the patch" >&2; exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$(problems "$1")
  if [[ -n $out ]]; then echo "test-present-damage: $1: $out" >&2; exit 1; fi
  echo "test-present-damage: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-damage.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-damage-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-present-damage.c" -o "$work/test-present-damage"
"$work/test-present-damage"
