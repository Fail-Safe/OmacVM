#!/bin/bash
# Direct to display (omacvm-cocoa-present-direct.patch): with OMACVM_GL_DIRECT=1 and the vsync present the
# patched ui/cocoa.m makes the view's layer a CAMetalLayer (a Metal device and command queue through dlsym
# and by name: Metal is not linked into QEMU), keeps QEMU's own surfaces (lossless, half float, partial
# draws) and copies each shown frame with a Metal blit into one of the layer's drawables (lossless-compressed
# where the 8-bit surfaces are). Drawables come from a queue of their own, QEMU's thread never waits for one
# (none spare = all surfaces busy), a drawable of an old size or kind is dropped when taken, the layer's
# size and kind change on that queue (never during a nextDrawable), the surface stays in use until the GPU
# has copied it, the drawable goes with the frame's surface, and the plain layer comes back for the run when
# Metal cannot read a frame. Without an argument: only that the checks catch the code without it (CI).
# Whether the display really shows the window itself: work/direct-display (ddbench on a Mac; qemu.log in a VM).
#   test-present-direct.sh                       (CI)
#   test-present-direct.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-direct.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A function's body by the start of its definition (not a declaration: no ';' at the end of the line).
bodyx() { awk -v h="$2" 'index($0, h) == 1 && !/;[[:space:]]*$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 newl fetch take dalloc fits alloc present show dshow tex put fallback status init part
  newl=$(bodyx "$m" 'static CALayer *omacvm_direct_layer_new(void)')
  fetch=$(bodyx "$m" 'static void omacvm_direct_fetch(void)')
  take=$(bodyx "$m" 'static id<CAMetalDrawable> omacvm_direct_take(void)')
  dalloc=$(bodyx "$m" 'static void omacvm_direct_alloc(uint32_t w, uint32_t h, bool deep, bool linear,')
  fits=$(bodyx "$m" 'static bool omacvm_direct_fits(id<CAMetalDrawable> d, uint32_t w, uint32_t h,')
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear')
  present=$(bodyx "$m" 'static bool cocoa_gl_present(void)')
  show=$(bodyx "$m" 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,')
  dshow=$(bodyx "$m" 'static bool omacvm_direct_show(IOSurfaceRef surf)')
  tex=$(bodyx "$m" 'static id<MTLTexture> omacvm_direct_texture(IOSurfaceRef surf)')
  put=$(bodyx "$m" 'static void surface_put(IOSurfaceRef surf)')
  fallback=$(bodyx "$m" 'static void omacvm_direct_fallback(const char *why)')
  status=$(bodyx "$m" 'static void omacvm_direct_status(void)')
  init=$(awk '/if \(cgl && cocoa_gl_present_iosurface_wanted\(\)\) \{/ {on=1} on {print} on && /\[self setLayer:layer\];/ {exit}' "$m")
  # The statement that decides a partial draw, on one line.
  part=$(awk '/bool part = /{on=1} on {printf "%s ", $0} on && /;/ {exit}' <<<"$present")

  # The layer: CAMetalLayer only when asked, with the vsync present, and a Metal device and queue.
  grep -q 'CALayer \*layer = omacvm_direct_layer_new();' <<<"$init" && grep -q 'layer = \[\[CALayer alloc\] init\];' <<<"$init" ||
    echo "the view's layer is never a CAMetalLayer (or has no plain fallback)"
  grep -q 'getenv("OMACVM_GL_DIRECT")' <<<"$newl" || echo "OMACVM_GL_DIRECT is not read"
  grep -q 'getenv("OMACVM_GL_VSYNC")' <<<"$newl" && grep -q 'needs the vsync present' <<<"$newl" ||
    echo "direct to display without the vsync present (frames would be set as contents on a CAMetalLayer)"
  grep -q 'dlsym(mtl, "MTLCreateSystemDefaultDevice")' <<<"$newl" && grep -q 'newCommandQueue' <<<"$newl" &&
    grep -q 'no Metal device' <<<"$newl" ||
    echo "no Metal device and queue through dlsym (Metal is not linked into QEMU), or no way back without one"
  grep -q 'setFramebufferOnly:NO' <<<"$newl" || echo "drawables a Metal blit cannot write (framebufferOnly)"
  grep -q 'setMaximumDrawableCount:3' <<<"$newl" || echo "the drawables are not capped at three"
  # Drawables: fetched on their own queue, taken without waiting.
  grep -q 'dispatch_async(direct_queue' <<<"$fetch" && grep -q 'nextDrawable' <<<"$fetch" ||
    echo "drawables are not fetched on a queue of their own"
  [[ $(grep -c 'nextDrawable\]' "$m") == 1 ]] || echo "nextDrawable is called outside the fetch queue (QEMU's thread could wait)"
  grep -q 'direct_spare = nil;' <<<"$take" && grep -q 'omacvm_direct_fetch();' <<<"$take" ||
    echo "the spare drawable is not taken and fetched again"
  grep -q 'qemu_bh_schedule(present_bh)' <<<"$fetch" || echo "a frame that waited for a drawable is not drawn when one comes"
  # Our own surfaces stay (lossless, half float); the drawables follow them, changed on the drawables' queue.
  grep -q 'omacvm_direct_alloc(w, h, deep, linear, packed);' <<<"$alloc" && grep -q 'IOSurfaceCreate' <<<"$alloc" &&
    ! grep -q 'Direct to display: no surfaces of our own' <<<"$alloc" ||
    echo "QEMU's own surfaces (lossless, half float) are not kept, or the drawables do not follow them"
  awk '/dispatch_async\(direct_queue, \^\{/ {on=1} on && /setDrawableSize:/ {print "q"; exit}' <<<"$dalloc" | grep -q '^q$' &&
    grep -q 'MTLPixelFormatRGBA16Float' <<<"$dalloc" && grep -q 'setColorspace:cs' <<<"$dalloc" ||
    echo "the layer's size, kind or colours change outside the drawables' queue (or not at all)"
  grep -q 'NSSelectorFromString(@"setWantsIOSurfaceCompression:")' <<<"$dalloc" && grep -q 'respondsToSelector:sel' <<<"$dalloc" ||
    echo "no lossless-compressed drawables (or a private selector called unchecked)"
  grep -q 'qatomic_inc(&direct_gen);' <<<"$dalloc" || echo "Metal textures of old surfaces are kept after new ones are made"
  # The draw: a frame needs a drawable that fits (else all busy); partial draws stay.
  grep -q 'drawable = omacvm_direct_take();' <<<"$present" && grep -q 'omacvm_direct_fits(drawable' <<<"$present" &&
    grep -q 'i = present_nsurf;' <<<"$present" && grep -q '\[t width\] == w' <<<"$fits" ||
    echo "a frame is drawn without a drawable that fits it (or waits for one)"
  grep -q 'direct_n' <<<"$part" && echo "partial draws are off with direct to display"
  grep -q 'iosurface\]' <<<"$present" && echo "GL draws into the drawables (no lossless surfaces then)"
  grep -q 'omacvm_direct_hold(surf, drawable);' <<<"$present" || echo "a frame's drawable is not kept with its surface"
  # Show: the Metal copy, the surface in use until the GPU copied it.
  grep -q 'if (!drawn_direct) {' <<<"$show" && grep -q 'omacvm_direct_show(surf)' <<<"$show" ||
    echo "the frame's drawable is not presented (or contents are set on the CAMetalLayer)"
  grep -q 'copyFromTexture:src toTexture:dst' <<<"$dshow" && grep -q 'presentDrawable:d' <<<"$dshow" ||
    echo "frames are not copied into the drawables with Metal"
  awk '/IOSurfaceIncrementUseCount\(surf\);/ {a=1} a && /addCompletedHandler/ {b=1} b && /IOSurfaceDecrementUseCount\(surf\);/ {print "ok"; exit}' <<<"$dshow" |
    grep -q '^ok$' || echo "QEMU can draw into a surface the GPU is still copying"
  grep -q 'NSClassFromString(@"MTLTextureDescriptor")' <<<"$tex" && grep -q 'newTextureWithDescriptor:d iosurface:surf' <<<"$tex" &&
    grep -q 'gen != direct_tex_gen' <<<"$tex" ||
    echo "no Metal texture per surface (by name: Metal is not linked), or old ones are never let go"
  grep -q 'omacvm_direct_fallback("Metal cannot read the frames");' <<<"$dshow" ||
    echo "no way back to the plain layer when Metal cannot read a frame"
  grep -q 'omacvm_direct_put(surf);' <<<"$put" || echo "drawables of shown or dropped frames are never let go"
  grep -q 'qatomic_xchg(&present_direct, 0)' <<<"$fallback" && grep -q 'CALayer \*layer = \[\[CALayer alloc\] init\];' <<<"$fallback" &&
    grep -q 'addSublayer:sub' <<<"$fallback" || echo "the fallback does not bring back the plain layer with its sublayers (once)"
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
for want in "never a CAMetalLayer" "OMACVM_GL_DIRECT is not read" "without the vsync present" "no Metal device and queue" \
  "framebufferOnly" "capped at three" "fetched on a queue" "spare drawable is not taken" "a frame that waited" \
  "do not follow them" "outside the drawables' queue" "no lossless-compressed drawables" "Metal textures of old surfaces" \
  "without a drawable that fits" "not kept with its surface" "is not presented" "not copied into the drawables" \
  "still copying" "no Metal texture per surface" "no way back to the plain layer" "never let go" \
  "fallback does not bring back" "is not logged"; do
  [[ $old == *"$want"* ]] || { echo "test-present-direct: the checks miss the old code: $want" >&2; exit 1; }
done
# A nextDrawable on QEMU's thread (outside the fetch queue) is caught.
{ cat "$work/old.m"; printf 'static void omacvm_direct_fetch(void)\n{\n    dispatch_async(direct_queue, ^{ id d = [l nextDrawable]; });\n}\nstatic bool x(void)\n{\n    [l nextDrawable];\n}\n'; } > "$work/twice.m"
[[ $(problems "$work/twice.m") == *"nextDrawable is called outside the fetch queue"* ]] ||
  { echo "test-present-direct: a nextDrawable on QEMU's thread is not caught" >&2; exit 1; }
# GL drawing into the drawables (the first version: no lossless surfaces, no partial draws) is caught.
awk '{print} /^static bool cocoa_gl_present\(void\)$/ {getline; print; print "    IOSurfaceRef ds = drawable ? [[drawable texture] iosurface] : NULL;"; print "    bool part = present_damage_on &&"; print "                direct_n < 0;"}' "$work/old.m" > "$work/gl.m"
gl=$(problems "$work/gl.m")
[[ $gl == *"GL draws into the drawables"* && $gl == *"partial draws are off"* ]] ||
  { echo "test-present-direct: GL drawing into the drawables is not caught" >&2; exit 1; }

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
