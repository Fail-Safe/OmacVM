#!/bin/bash
# Lossless-compressed present surfaces (omacvm-cocoa-present-lossless.patch): the patched ui/cocoa.m makes
# its 8-bit surfaces as '&BGA' through CoreVideo, falls back to plain 'BGRA' for the run when one cannot be
# made or bound, keeps half-float surfaces as they are, reads OMACVM_GL_LOSSLESS, and never reads a present
# surface on the CPU (a compressed one cannot be). Without an argument: only that the checks catch the code
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
  ! grep -q 'IOSurfaceLock(present_surf\|IOSurfaceGetBaseAddress(present_surf' "$m" ||
    echo "a present surface is read on the CPU (a compressed one cannot be)"
}

cat > "$work/old.m" <<'EOF2'
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    for (int i = 0; i < present_nsurf && ok; i++) {
        present_surf[i] = IOSurfaceCreate((CFDictionaryRef)props);
    }
}
EOF2
old=$(problems "$work/old.m")
for want in "not made lossless-compressed" "still plain" "no plain surfaces after" "OMACVM_GL_LOSSLESS is not read"; do
  [[ $old == *"$want"* ]] || { echo "test-present-lossless: the checks miss the old code: $want" >&2; exit 1; }
done
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
