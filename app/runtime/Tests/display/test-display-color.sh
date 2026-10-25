#!/bin/bash
# Display colour present (omacvm-cocoa-display-color-logic.patch,
# omacvm-cocoa-display-color.patch): the logic patch makes ui/omacvm-dispcolor.h
# in an empty folder, test-display-color.c runs its rules and the table's check,
# test-display-color-shader.m its shader on the software renderer against macOS's
# own conversion. With ui/cocoa.m as argument (the runtime build, after the wiring
# patch): also that the patched file is wired as tested (and the checks catch
# code without it).
#   test-display-color.sh                       (CI)
#   test-display-color.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-display-color.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-display-color-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-display-color.c" -o "$work/t" \
  -framework CoreGraphics
"$work/t"
cc -fobjc-arc -Wall -Wextra -Werror -I"$work/ui" "$here/test-display-color-shader.m" \
  -framework Foundation -framework OpenGL -framework CoreGraphics -o "$work/s"
"$work/s"

bodyx() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 present alloc look init changed wanted
  present=$(bodyx "$m" 'static bool cocoa_gl_present(void)')
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear,')
  look=$(bodyx "$m" 'static void omacvm_dc_look(void)')
  init=$(bodyx "$m" 'static void omacvm_bright_init(void)')
  changed=$(bodyx "$m" '- (void)windowDidChangeScreen:(NSNotification *)notification')
  wanted=$(bodyx "$m" 'static bool omacvm_dc_wanted_now(bool deep, bool linear, bool splash)')
  grep -q '#include "ui/omacvm-dispcolor.h"' "$m" || echo "ui/omacvm-dispcolor.h is not used"
  # Each frame: the kind wanted, the surfaces made for it, drawn as the surfaces are.
  grep -q 'bool dc = omacvm_dc_wanted_now(deep, linear, splash);' <<<"$present" ||
    echo "the present does not ask whether to convert (or not for the boot logo)"
  grep -q 'cocoa_gl_present_alloc(w, h, deep, linear, dc)' <<<"$present" || echo "the surfaces are not made for the display's space"
  grep -q 'present_dc && omacvm_dc_blit(flip)' <<<"$present" || echo "the frames are not drawn as the surfaces are"
  [[ $(grep -c 'qemu_gl_run_texture_blit(present_gls' <<<"$present") == 1 ]] || echo "another blit into the present surfaces"
  grep -q 'omacvm_dc_wanted(&st)' <<<"$wanted" && grep -q '.splash = splash' <<<"$wanted" &&
    grep -q '.deep = deep' <<<"$wanted" && grep -q '.linear = linear' <<<"$wanted" ||
    echo "the tested rule does not decide (HDR, extra brightness, the boot logo)"
  grep -q 'getenv("OMACVM_GL_DISPLAY_COLOR")' <<<"$wanted" || echo "OMACVM_GL_DISPLAY_COLOR is not read"
  # The surfaces: tagged with the table's space; a new space or kind is made at once (at most once a second).
  grep -q 'cocoa_gl_present_colorspace(deep, linear, dc)' <<<"$alloc" || echo "the surfaces are not tagged with the display's space"
  grep -q 'dc != present_dc || (dc && present_surf_gen != present_dc_gen)' <<<"$alloc" ||
    echo "a new display space waits for the hold-off"
  grep -q 'present_surf_gen == present_dc_gen' <<<"$alloc" || echo "surfaces of another display's space are kept"
  # The table: macOS's conversion, checked before use.
  grep -q 'omacvm_dc_fill(cs, OMACVM_DC_N, table)' "$m" && grep -q 'err > OMACVM_DC_MAX_ERR' "$m" ||
    echo "the table is used without the check"
  grep -q 'OMACVM_DC_FRAG' "$m" || echo "the shader is not the tested one"
  # The main thread follows the window's display and its profile, and redraws.
  grep -q 'qatomic_inc(&dc_gen);' <<<"$look" && grep -q 'qemu_bh_schedule(omacvm_bright_bh);' <<<"$look" ||
    echo "a new display space does not redraw"
  grep -q '\[screen colorSpace\] CGColorSpace' <<<"$look" || echo "not the window's display's space"
  grep -q 'NSWindowDidChangeScreenProfileNotification' <<<"$init" || echo "a new display profile is not followed"
  grep -q 'omacvm_dc_look();' <<<"$init" || echo "the space is not read at start"
  grep -q 'omacvm_dc_look();' <<<"$changed" || echo "a move to another display is not followed"
}

# The checks catch code without it (the present before this patch).
cat > "$work/old.m" <<'EOF2'
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    CGColorSpaceRef cs = cocoa_gl_present_colorspace(deep, linear);
}
static bool cocoa_gl_present(void)
{
    if (!cocoa_gl_present_alloc(w, h, deep, linear)) {
    }
        if (!boost || !omacvm_bright_blit(flip, linear ? gain : OMACVM_BRIGHT_ONE, pq)) {
            qemu_gl_run_texture_blit(present_gls, flip);
        }
}
EOF2
old=$(problems "$work/old.m")
for want in "omacvm-dispcolor.h is not used" "does not ask whether to convert" "not drawn as the surfaces are" \
            "not tagged with the display's space" "waits for the hold-off" "not followed"; do
  [[ $old == *"$want"* ]] || { echo "test-display-color: the checks miss the old code: $want" >&2; exit 1; }
done

if [[ $# -ge 1 ]]; then
  out=$(problems "$1")
  if [[ -n $out ]]; then
    echo "test-display-color: $1:" >&2
    echo "$out" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "test-display-color: $1: wiring ok"
fi
