#!/bin/bash
# Extra brightness (ADR 0050, omacvm-cocoa-extra-brightness-logic.patch,
# omacvm-cocoa-extra-brightness.patch): the logic patch makes
# ui/omacvm-bright.h in an empty folder, test-extra-brightness.c runs its
# rules and test-extra-brightness-shader.m its shader on the software renderer. With ui/cocoa.m as argument (the runtime build, after the wiring
# patch): also that the patched file is wired as tested (and the checks
# catch code without it).
#   test-extra-brightness.sh                       (CI)
#   test-extra-brightness.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-extra-brightness.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-extra-brightness-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-extra-brightness.c" -o "$work/t" -lm
"$work/t"
# The same shader on Apple's software renderer (never a real GPU), against the C decode.
cc -fobjc-arc -Wall -Wextra -Werror -I"$work/ui" "$here/test-extra-brightness-shader.m" \
  -framework Foundation -framework OpenGL -o "$work/s"
"$work/s"

bodyx() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 present alloc follow look splash seen init
  present=$(bodyx "$m" 'static bool cocoa_gl_present(void)')
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)')
  follow=$(bodyx "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)')
  look=$(bodyx "$m" 'static void omacvm_bright_look(void)')
  splash=$(awk '/^static void omacvm_splash_draw_with\(/ {on=1} on {print} on && /^}$/ {exit}' "$m")
  seen=$(bodyx "$m" '- (void)omacvmWindowSeen:(NSNotification *)note')
  init=$(bodyx "$m" 'static void omacvm_bright_init(void)')
  grep -q '#include "ui/omacvm-bright.h"' "$m" || echo "ui/omacvm-bright.h is not used"
  # The switch: the app's key, read live (KVO), again when seen; the env for a QEMU not started as the app.
  grep -q 'boolForKey:@"extraBrightness"' "$m" || echo "the app's extraBrightness key is not read"
  grep -q 'addObserver:watch' <<<"$init" && grep -q 'forKeyPath:@"extraBrightness"' <<<"$init" ||
    echo "the switch is not watched (KVO): a change waits for the next start"
  grep -q 'getenv("OMACVM_EXTRA_BRIGHT")' "$m" || echo "OMACVM_EXTRA_BRIGHT is not read"
  grep -q 'omacvm_bright_reread();' <<<"$seen" || echo "the switch is not read again when the window is seen again"
  # The layer: EDR and toneMapMode never for a frame drawn in linear light.
  grep -q 'cocoa_gl_present_hdr_wanted() || linear' <<<"$follow" || echo "the layer has no EDR for extra brightness"
  grep -q 'setToneMapMode:hdr ? CAToneMapModeNever' <<<"$follow" || echo "macOS tone-maps the boosted frames"
  # The surfaces: half-float, extended linear sRGB, content headroom 2.
  grep -q "half ? (uint32_t)'RGhA'" <<<"$alloc" || echo "boosted frames are not in half-float surfaces"
  grep -q 'kCGColorSpaceExtendedLinearSRGB' "$m" || echo "the surfaces are not tagged extended linear sRGB"
  grep -q 'kIOSurfaceContentHeadroom' <<<"$alloc" && grep -q 'OMACVM_BRIGHT_TARGET' <<<"$alloc" ||
    echo "the surfaces do not say they need 2x (macOS may raise the panel to its most)"
  grep -q 'linear != present_linear' <<<"$alloc" || echo "turning it on or off waits for the hold-off"
  # Every draw into the present surfaces follows the kind the surfaces have.
  grep -q 'bool boost = present_linear;' <<<"$present" || echo "the kind drawn follows the switch, not the surfaces"
  grep -q 'omacvm_bright_blit(flip, linear ? gain : OMACVM_BRIGHT_ONE)' <<<"$present" ||
    echo "the guest's frames skip the gain shader"
  grep -q 'omacvm_splash_draw_with(present_gls, present_w, present_h,' <<<"$present" &&
    grep -q '!omacvm_desktop_up, true, boost);' <<<"$present" || echo "the boot logo does not know the surfaces' kind"
  grep -q 'rgb\[i\] = omacvm_bright_linear(rgb\[i\]);' <<<"$splash" || echo "the boot logo's clear colour is not decoded in linear surfaces"
  grep -q 'omacvm_bright_blit(top_first, OMACVM_BRIGHT_ONE)' <<<"$splash" || echo "the boot logo skips the gain shader in linear surfaces"
  grep -q 'bool linear = !splash && !pq' <<<"$present" || echo "the boot logo or PQ frames are boosted"
  [[ $(grep -c 'qemu_gl_run_texture_blit(present_gls' "$m") == 1 ]] || echo "another blit into the present surfaces"
  # Each frame's kind reaches the layer with the frame.
  grep -q 'cocoa_gl_present_queue_frame(surf, filter, flushed, boost);' "$m" &&
    grep -q 'show.flushed, show.linear);' "$m" && grep -q 'cocoa_gl_layer_follow(layer, surf, boost);' "$m" ||
    echo "the layer does not get the frame's kind"
  # The shader is made when first needed, never at start.
  grep -q 'omacvm_bright_program()' <<<"$present" || echo "the shader is not made on present_ctx when needed"
  grep -q 'OMACVM_BRIGHT_FRAG' "$m" && ! grep -q 'qemu_gl_init_shader.*OMACVM_BRIGHT' "$m" ||
    echo "the shader is not the tested one"
  # A redraw on a change, in both present modes; the look stops when not needed.
  grep -q 'omacvm_bright_bh = aio_bh_new(iohandler_get_aio_context(),' "$m" || echo "no redraw on a change (static desktop)"
  grep -q 'qemu_bh_schedule(omacvm_bright_bh);' <<<"$look" || echo "a change does not redraw"
  grep -q 'omacvm_bright_timer_run(want && !pq && seen);' <<<"$look" || echo "the look does not stop when off, unseen or not on this display"
  grep -q 'omacvm_bright_gain(now, potential)' <<<"$look" || echo "the gain is not the window's display's"
  grep -q 'getenv("OMACVM_TEST_EDR")' "$m" || echo "no test hook for the display"
}

# The checks catch code without it (3.1.27's present).
cat > "$work/old.m" <<'EOF2'
static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf)
{
    BOOL hdr = IOSurfaceGetPixelFormat(surf) == 'RGhA' &&
               present_color == 1 && cocoa_gl_present_hdr_wanted();
    if ([layer wantsExtendedDynamicRangeContent] != hdr) {
        [layer setToneMapMode:hdr ? CAToneMapModeNever : CAToneMapModeAutomatic];
    }
}
static bool cocoa_gl_present(void)
{
    if (splash) {
        omacvm_splash_draw_with(present_gls, present_w, present_h,
                                !omacvm_desktop_up, true);
    } else {
        qemu_gl_run_texture_blit(present_gls, flip);
    }
}
EOF2
old=$(problems "$work/old.m")
for want in "key is not read" "not watched" "no EDR for extra brightness" "skip the gain shader" "clear colour" "no redraw"; do
  [[ $old == *"$want"* ]] || { echo "test-extra-brightness: the checks miss the old code: $want" >&2; exit 1; }
done

(( $# )) || exit 0
m=$1
out=$(problems "$m")
if [[ -n $out ]]; then echo "test-extra-brightness: $m: $out" >&2; exit 1; fi
echo "test-extra-brightness: $m: wiring ok"
