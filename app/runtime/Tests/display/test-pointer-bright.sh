#!/bin/bash
# The pointer's layer with extra brightness (omacvm-cocoa-pointer-bright*.patch, ADR 0054):
#   - the rules: the logic patches make ui/omacvm-pointer-bright.h and
#     ui/omacvm-bright.h in an empty folder and test-pointer-bright.c runs
#     against them (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (the image in half floats,
#     extended linear sRGB, times the frames' gain while they are boosted,
#     the layer with EDR; the 8-bit image otherwise; both premultiplied, as
#     virtio-gpu sends it; the gain follows the frames' in omacvm_bright_look);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check
#     fails on that code (CI: a stub; the runtime build: the real cocoa.m
#     before the patch).
#   test-pointer-bright.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
# One line per check: "ok WHAT" or "FAIL WHAT".
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
checks() {
  local m=$1 set img look
  set=$(body "$m" '- (void)setCursor:(QEMUCursor *)given_cursor')
  img=$(body "$m" '- (void)updateCursorImage')
  look=$(body "$m" 'static void omacvm_bright_look(void)')
  chk "the rules are included" grep -q '#include "ui/omacvm-pointer-bright.h"' "$m"
  chk "a new image from the guest goes through updateCursorImage" has "$set" '[self updateCursorImage];'
  chk "boosted: the image takes the frames' gain" has "$img" 'omacvm_pointer_bright_pixels(cursor->data, n, gain,'
  chk "boosted: only above 1x" has "$img" 'BOOL boost = gain > OMACVM_BRIGHT_ONE;'
  chk "boosted: extended linear sRGB" has "$img" 'CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB)'
  chk "boosted: half floats, premultiplied" has "$img" 'kCGBitmapByteOrder16Little | kCGBitmapFloatComponents |'
  chk "boosted: 64 bits a pixel" has "$img" 'CGImageCreate(cursor->width, cursor->height, 16, 64, cursor->width * 8,'
  chk "not boosted: the 8-bit image, premultiplied as virtio-gpu sends it" has "$img" 'kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, //bitmapInfo'
  chk "no image takes it as straight alpha (soft edges dark)" bash -c '[[ -n $1 ]] && ! grep -qF "kCGImageAlphaFirst" <<<"$1"' _ "$img"
  chk "the layer has EDR while boosted" has "$img" '[cursorLayer setWantsExtendedDynamicRangeContent:boost];'
  chk "macOS does not tone-map it (as the frames)" has "$img" 'setToneMapMode:boost ? CAToneMapModeNever : CAToneMapModeAutomatic'
  chk "it asks for 2x only (macOS 26+)" has "$img" 'CGFloat need = boost ? OMACVM_BRIGHT_TARGET : 0;'
  chk "the layer's headroom is set" has "$img" '[cursorLayer setContentsHeadroom:need];'
  chk "the gain follows the frames' (wanted and their gain)" has "$look" \
    'int pointer = omacvm_pointer_gain(qatomic_read(&omacvm_bright_wanted),'
  chk "the frames' own gain, not the display's now" has "$look" 'qatomic_read(&omacvm_bright_gain_c));'
  chk "a moved gain makes the image again" has "$look" '[cocoaView updateCursorImage];'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-bright.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf -- '- (void)setCursor:(QEMUCursor *)given_cursor\n{\n    image = CGImageCreate(cursor->width, cursor->height, 8, 32, cursor->width * 4, colorspace,\n'
      printf '        kCGBitmapByteOrder32Little | kCGImageAlphaFirst, provider, NULL, 0, kCGRenderingIntentDefault);\n'
      printf '    [cursorLayer setContents:(id)image];\n}\n'
      printf 'static void omacvm_bright_look(void)\n{\n    qatomic_set(&omacvm_bright_gain_c, gain);\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$(checks "$1" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-pointer-bright: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-pointer-bright: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-bright.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-extra-brightness-logic.patch"
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-pointer-bright-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-pointer-bright.c" -o "$work/test-pointer-bright" -lm
"$work/test-pointer-bright"
