#!/bin/bash
# Lossless-compressed present surfaces (omacvm-cocoa-present-lossless.patch): the patched ui/cocoa.m makes
# its 8-bit surfaces as '&BGA' through CoreVideo, falls back to plain 'BGRA' for the run when one cannot be
# made or bound, keeps half-float surfaces as they are, reads OMACVM_GL_LOSSLESS and never reads a present
# surface on the CPU. glReadPixels from one (it crashes on a compressed one) happens only in the partial
# present's check mode (OMACVM_GL_PRESENT_DAMAGE=check), which keeps the surfaces plain. Without an argument: only that the checks catch the code
# without it (CI); GL drawing into such a surface is checked on the Mac by work/window-path/lbcheck.m (a GPU).
#   test-present-lossless.sh                       (CI)
#   test-present-lossless.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-lossless.XXXXXX")
trap 'rm -rf "$work"' EXIT

bodyx() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 alloc packed
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear')
  packed=$(bodyx "$m" 'static IOSurfaceRef cocoa_gl_present_packed(uint32_t w, uint32_t h)')
  grep -q 'kCVPixelFormatType_Lossless_32BGRA' <<<"$packed" && grep -q 'CVPixelBufferGetIOSurface(pb)' <<<"$packed" &&
    grep -q 'CFRetain(surf);' <<<"$packed" || echo "the surfaces are not made lossless-compressed (or not kept)"
  grep -q 'bool packed = !half && present_lossless == 1;' <<<"$alloc" || echo "half-float surfaces would be compressed too, or the switch is not used"
  grep -q 'packed ? cocoa_gl_present_packed(w, h)' <<<"$alloc" || echo "the 8-bit surfaces are still plain"
  grep -q 'present_lossless = 0;' <<<"$alloc" && grep -q 'goto again;' <<<"$alloc" ||
    echo "no plain surfaces after a lossless one fails (a black window)"
  grep -q 'getenv("OMACVM_GL_LOSSLESS")' <<<"$alloc" || echo "OMACVM_GL_LOSSLESS is not read"
  grep -q '@available(macOS 27.0, \*)' <<<"$alloc" || echo "lossless surfaces on a macOS they are not checked on"
  ! grep -q 'IOSurfaceLock(present_surf\|IOSurfaceGetBaseAddress(present_surf' "$m" ||
    echo "a present surface is read on the CPU (a compressed one cannot be)"
  grep -q 'getenv("OMACVM_GL_PRESENT_DAMAGE")' <<<"$alloc" &&
    grep -q 'OMACVM_GL_PRESENT_DAMAGE=check reads them back' <<<"$alloc" ||
    echo "the partial present's check mode gets compressed surfaces (its glReadPixels crashes on them)"
  # glReadPixels with a present surface attached crashes on a compressed one. Only the partial present's
  # check mode does it, and it keeps the surfaces plain (above).
  local readers
  readers=$(present_readers "$m")
  [[ -z $readers || $readers == cocoa_gl_present_pd_check ]] ||
    echo "a present surface is read back with glReadPixels outside the check mode: ${readers//$'\n'/ }"
}
# Functions that call glReadPixels while a present surface (present_tex[...]) is the framebuffer's attachment.
present_readers() {
  awk '
    /^[A-Za-z_].*\(/ && !/;[[:space:]]*$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, p, /[ *]+/); fn = p[n]; att = 0; st = "" }
    { st = st $0 }
    /;/ {
      if (st ~ /glFramebufferTexture2D\(/) att = (st ~ /present_tex\[/)
      if (st ~ /glReadPixels\(/ && att && !(fn in seen)) { seen[fn] = 1; print fn }
      st = ""
    }' "$1"
}

cat > "$work/old.m" <<'EOF2'
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    for (int i = 0; i < present_nsurf && ok; i++) {
        present_surf[i] = IOSurfaceCreate((CFDictionaryRef)props);
    }
}

static void cocoa_gl_present_snapshot(unsigned n)
{
    glBindFramebuffer(GL_FRAMEBUFFER, present_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE, present_tex[n], 0);
    glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, a);
}

static void cocoa_gl_present_guest(GLuint t)
{
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE, present_tex[0], 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t, 0);
    glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, a);
}
EOF2
old=$(problems "$work/old.m")
for want in "not made lossless-compressed" "still plain" "no plain surfaces after" "OMACVM_GL_LOSSLESS is not read" "not checked on" \
  "check mode gets compressed surfaces" "glReadPixels outside the check mode: cocoa_gl_present_snapshot"; do
  [[ $old == *"$want"* ]] || { echo "test-present-lossless: the checks miss the old code: $want" >&2; exit 1; }
done
[[ $old != *cocoa_gl_present_guest* ]] ||
  { echo "test-present-lossless: a readback of another texture counts as a present surface's" >&2; exit 1; }
echo "test-present-lossless: the checks catch the code without it"

if [[ $# -ge 1 ]]; then
  out=$(problems "$1")
  if [[ -n $out ]]; then
    echo "test-present-lossless: $1:" >&2
    echo "$out" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "test-present-lossless: $1: wiring ok"
fi
