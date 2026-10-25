#!/bin/bash
# Direct to display (omacvm-cocoa-present-direct.patch): with OMACVM_GL_DIRECT=1 and the vsync present the
# patched ui/cocoa.m makes the view's layer a CAMetalLayer (a Metal device through dlsym, drawables GL can
# draw into), gets drawables on a queue of its own and never waits for one on QEMU's thread (no spare one =
# all surfaces busy), sizes the drawables where it made surfaces, binds each drawable's IOSurface to GL,
# draws no partial frames into them, presents a frame's drawable where it set the layer's contents, lets
# the drawable go with the frame's surface, and goes back to the plain layer for the run when GL cannot
# draw into one. Without an argument: only that the checks catch the code without it (CI). Whether the
# display really shows the window itself: work/direct-display (ddbench on a Mac; qemu.log in a VM).
#   test-present-direct.sh                       (CI)
#   test-present-direct.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-direct.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A function's body by the start of its definition (not a declaration: no ';' at the end of the line).
bodyx() { awk -v h="$2" 'index($0, h) == 1 && !/;[[:space:]]*$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 newl fetch take alloc present show put fallback status init
  newl=$(bodyx "$m" 'static CALayer *omacvm_direct_layer_new(void)')
  fetch=$(bodyx "$m" 'static void omacvm_direct_fetch(void)')
  take=$(bodyx "$m" 'static id<CAMetalDrawable> omacvm_direct_take(void)')
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear')
  present=$(bodyx "$m" 'static bool cocoa_gl_present(void)')
  show=$(bodyx "$m" 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,')
  put=$(bodyx "$m" 'static void surface_put(IOSurfaceRef surf)')
  fallback=$(bodyx "$m" 'static void omacvm_direct_fallback(const char *why)')
  status=$(bodyx "$m" 'static void omacvm_direct_status(void)')
  init=$(awk '/if \(cgl && cocoa_gl_present_iosurface_wanted\(\)\) \{/ {on=1} on {print} on && /\[self setLayer:layer\];/ {exit}' "$m")

  # The layer: CAMetalLayer only when asked, with the vsync present, and a Metal device.
  grep -q 'CALayer \*layer = omacvm_direct_layer_new();' <<<"$init" && grep -q 'layer = \[\[CALayer alloc\] init\];' <<<"$init" ||
    echo "the view's layer is never a CAMetalLayer (or has no plain fallback)"
  grep -q 'getenv("OMACVM_GL_DIRECT")' <<<"$newl" || echo "OMACVM_GL_DIRECT is not read"
  grep -q 'getenv("OMACVM_GL_VSYNC")' <<<"$newl" && grep -q 'needs the vsync present' <<<"$newl" ||
    echo "direct to display without the vsync present (frames would be set as contents on a CAMetalLayer)"
  grep -q 'dlsym(mtl, "MTLCreateSystemDefaultDevice")' <<<"$newl" && grep -q 'no Metal device' <<<"$newl" ||
    echo "no Metal device through dlsym (Metal is not linked into QEMU), or no way back without one"
  grep -q 'setFramebufferOnly:NO' <<<"$newl" || echo "drawables GL cannot draw into (framebufferOnly)"
  grep -q 'setMaximumDrawableCount:3' <<<"$newl" || echo "the drawables are not capped at three"
  # Drawables: fetched on their own queue, taken without waiting.
  grep -q 'dispatch_async(direct_queue' <<<"$fetch" && grep -q 'nextDrawable' <<<"$fetch" ||
    echo "drawables are not fetched on a queue of their own"
  [[ $(grep -c 'nextDrawable\]' "$m") == 1 ]] || echo "nextDrawable is called outside the fetch queue (QEMU's thread could wait)"
  grep -q 'direct_spare = nil;' <<<"$take" && grep -q 'omacvm_direct_fetch();' <<<"$take" ||
    echo "the spare drawable is not taken and fetched again"
  grep -q 'qemu_bh_schedule(present_bh)' <<<"$fetch" || echo "a frame that waited for a drawable is not drawn when one comes"
  # Size and kind where surfaces were made; no surfaces of our own.
  grep -q 'setDrawableSize:CGSizeMake(w, h)' <<<"$alloc" && grep -q 'MTLPixelFormatRGBA16Float' <<<"$alloc" &&
    grep -q 'setColorspace:dcs' <<<"$alloc" || echo "the drawables do not follow the frame's size, kind or colours"
  awk '/if \(omacvm_direct_on\(\)\) \{/ {on=1} on && /return true;/ {print "ret"; exit} on && /IOSurfaceCreate|cocoa_gl_present_packed\(w, h\)/ {print "made"; exit}' <<<"$alloc" |
    grep -q '^ret$' || echo "surfaces of our own are still made with direct to display"
  # The draw: the spare drawable bound to GL, none = busy, no partial frames.
  grep -q 'drawable = omacvm_direct_take();' <<<"$present" && grep -q 'CGLTexImageIOSurface2D(present_ctx, GL_TEXTURE_RECTANGLE' <<<"$present" &&
    grep -q 'i = direct_n < 0 ? present_nsurf : 0;' <<<"$present" || echo "frames are not drawn into the drawables (or wait for one)"
  grep -q 'direct_n < 0;' <<<"$present" || echo "partial draws into drawables that hold older frames"
  grep -q 'omacvm_direct_hold(surf, drawable);' <<<"$present" || echo "a frame's drawable is not kept with its surface"
  grep -q 'omacvm_direct_fallback("GL cannot draw into the drawables");' <<<"$present" ||
    echo "no way back to the plain layer when GL cannot draw into a drawable"
  # Show and put.
  grep -q 'if (!drawn_direct) {' <<<"$show" && grep -q 'omacvm_direct_show(surf)' <<<"$show" ||
    echo "the frame's drawable is not presented (or contents are set on the CAMetalLayer)"
  grep -q 'omacvm_direct_put(surf);' <<<"$put" || echo "drawables of shown or dropped frames are never let go"
  grep -q 'qatomic_set(&present_direct, 0);' <<<"$fallback" && grep -q 'CALayer \*layer = \[\[CALayer alloc\] init\];' <<<"$fallback" &&
    grep -q 'addSublayer:sub' <<<"$fallback" || echo "the fallback does not bring back the plain layer with its sublayers"
  # What the log says: Core Animation's status, only where the selector is there.
  grep -q 'NSSelectorFromString(@"displayCompositingInternalStatus")' <<<"$status" &&
    grep -q 'respondsToSelector:sel' <<<"$status" || echo "the direct/composited state is not logged (or a private selector is called unchecked)"
}

cat > "$work/old.m" <<'EOF2'
        if (cgl && cocoa_gl_present_iosurface_wanted()) {
            /* Frames arrive as IOSurfaces (cocoa_gl_present). */
            CALayer *layer = [[CALayer alloc] init];
            [layer setOpaque:YES];
            [self setLayer:layer];
        }
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    for (int i = 0; i < present_nsurf && ok; i++) {
        present_surf[i] = packed ? cocoa_gl_present_packed(w, h) :
                                   IOSurfaceCreate((CFDictionaryRef)props);
    }
}

static bool cocoa_gl_present(void)
{
    for (i = 0; i < present_nsurf; i++) {
        if (!IOSurfaceIsInUse(present_surf[n])) {
            break;
        }
    }
}

static void surface_put(IOSurfaceRef surf)
{
    IOSurfaceDecrementUseCount(surf);
    CFRelease(surf);
}

static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,
                                  bool linear)
{
    [layer setContents:(id)surf];
}
EOF2
old=$(problems "$work/old.m")
for want in "never a CAMetalLayer" "OMACVM_GL_DIRECT is not read" "without the vsync present" "no Metal device" \
  "framebufferOnly" "capped at three" "fetched on a queue" "spare drawable is not taken" "a frame that waited" \
  "do not follow the frame's size" "not drawn into the drawables" "partial draws" "not kept with its surface" \
  "no way back to the plain layer" "is not presented" "never let go" "fallback does not bring back" "is not logged"; do
  [[ $old == *"$want"* ]] || { echo "test-present-direct: the checks miss the old code: $want" >&2; exit 1; }
done
# A nextDrawable on QEMU's thread (outside the fetch queue) is caught.
{ cat "$work/old.m"; printf 'static void omacvm_direct_fetch(void)\n{\n    dispatch_async(direct_queue, ^{ id d = [l nextDrawable]; });\n}\nstatic bool x(void)\n{\n    [l nextDrawable];\n}\n'; } > "$work/twice.m"
[[ $(problems "$work/twice.m") == *"nextDrawable is called outside the fetch queue"* ]] ||
  { echo "test-present-direct: a nextDrawable on QEMU's thread is not caught" >&2; exit 1; }

if [[ $# -eq 0 ]]; then
  echo "test-present-direct: the checks catch the code without direct to display"
  exit 0
fi
out=$(problems "$1")
if [[ -n $out ]]; then
  echo "test-present-direct: $1:" >&2
  echo "$out" | sed 's/^/  /' >&2
  exit 1
fi
echo "test-present-direct: $1 is wired as tested"
