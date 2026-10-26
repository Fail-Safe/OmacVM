#!/bin/bash
# The guest's pointer over every display's window (omacvm-cocoa-pointer-heads*.patch,
# ADR 0054, #554):
#   - the rules: the logic patch makes ui/omacvm-pointer-heads.h in an empty
#     folder and test-pointer-heads.c runs against it (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (each other display's window has
#     a pointer layer above its frames; the guest's image and place for that
#     output go there, not only to the hidden macPointer; a window made again
#     shows the pointer as it is);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check
#     fails on that code (CI: a stub; the runtime build: the real cocoa.m
#     before the patch).
#   test-pointer-heads.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
# A function's or method's body: from its first line (HEAD starts it; a
# declaration ending in ';' is not it) to the first '}' at the line's start.
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
# One line per check: "ok WHAT" or "FAIL WHAT".
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
checks() {
  local m=$1 mouse define init layout on tex img
  mouse=$(body "$m" 'static void omacvm_head_mouse_set(DisplayChangeListener *dcl')
  define=$(body "$m" 'static void omacvm_head_cursor_define(DisplayChangeListener *dcl')
  init=$(body "$m" '- (id)initWithFrame:(NSRect)frame output:(int)index')
  layout=$(body "$m" '- (void)omacvmPointerLayout')
  on=$(body "$m" 'static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)')
  tex=$(body "$m" 'static void omacvm_head_scanout_texture(DisplayChangeListener *dcl')
  img=$(body "$m" 'static void omacvm_head_pointer_image(int output, QEMUCursor *c)')
  chk "the rules are included" grep -q '#include "ui/omacvm-pointer-heads.h"' "$m"
  chk "each other display's view has a pointer layer" has "$init" 'pointerLayer = [[CALayer alloc] init];'
  chk "the layer sits above the frames, as the main window's" has "$init" '[pointerLayer setZPosition:1];'
  chk "the layer's place is the image's top left" has "$init" '[pointerLayer setAnchorPoint:CGPointMake(0, 1)];'
  chk "the layer is on the view's layer" has "$init" '[[self layer] addSublayer:pointerLayer];'
  chk "the guest's image for that output goes to the layer (not only to macPointer)" \
    has "$define" 'omacvm_head_pointer_image(output, qemu_console_get_cursor(con));'
  chk "its place and on/off for that output go to the layer" has "$mouse" 'p->on = on;'
  chk "the output's size goes along with the place" has "$mouse" 'p->ow = ow;'
  chk "a new scanout of the output: its size again" has "$tex" 'omacvm_head_pointer_size(dcl);'
  chk "placed by the tested rules" has "$layout" 'omacvm_head_pointer_frame('
  chk "never with macPointer (the Mac's cursor shows it then)" has "$layout" '!omacvm_hwc.on'
  chk "shown only while the rules say so" has "$layout" '[pointerLayer setHidden:!f.shown];'
  chk "the image is copied (virtio-gpu reuses its buffer)" has "$img" 'CFDataRef data = CFDataCreate(NULL, (const UInt8 *)c->data,'
  chk "the image premultiplied, as virtio-gpu sends it" has "$img" 'kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,'
  chk "a resized view places it again" grep -qF '[super setFrameSize:size];
    [self omacvmPointerLayout];' "$m"
  chk "a new window shows the pointer as it is" has "$on" 'omacvm_head_pointer_apply(hd->output);'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-heads.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf 'static void omacvm_head_mouse_set(DisplayChangeListener *dcl, int x, int y, bool on)\n{\n'
      printf '    if (!omacvm_hwc.on) {\n        return;\n    }\n}\n'
      printf 'static void omacvm_head_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)\n{\n'
      printf '    if (!omacvm_hwc.on) {\n        return;\n    }\n}\n'
      printf -- '- (id)initWithFrame:(NSRect)frame output:(int)index\n{\n    output = index;\n}\n'
      printf 'static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)\n{\n    hd->dirty = true;\n}\n'; } > "$T/old.m"
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
  if [[ -n $out ]]; then echo "test-pointer-heads: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-pointer-heads: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-heads.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-pointer-heads-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-pointer-heads.c" -o "$work/test-pointer-heads" -lm
"$work/test-pointer-heads"
