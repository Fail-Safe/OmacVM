#!/bin/bash
# A click in another display's window keeps the pointer and the keys (#563,
# omacvm-cocoa-key-handback*.patch):
#   - the rules: the logic patch makes ui/omacvm-key-handback.h in an empty folder and
#     test-key-handback.c runs against it (the click kept, the escape combo, swipes,
#     Command-Tab and a hidden window let go as before, the key not back = let go);
#   - with a patched ui/cocoa.m: the wiring (the main window's resign asks the rules with
#     the event AppKit is handling, keeps nothing else, checks the key on the next turn;
#     handKeyBack uses the same rule) and that the other let-go paths are as they were
#     (another app in front, isKeyboardCaptured, the click hands the key back first);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check fails on that
#     code (CI: a stub of the old code; the runtime build: the real cocoa.m before the patch).
#   test-key-handback.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
lacks() { [[ -n $1 ]] && hasnt "$1" "$2"; }
order() {
  awk -v a="$2" -v b="$3" -v c="${4:-}" '
    !x && index($0, a) {x=NR; next}
    x && !y && index($0, b) {y=NR; if (c == "") exit; next}
    y && c != "" && !z && index($0, c) {z=NR; exit}
    END {exit !(x && y && (c == "" || z))}' <<<"$1"
}
# What the patch adds: each fails on the code before it.
checks() {
  local m=$1 resign kept letgo back
  resign=$(body "$m" '- (void) windowDidResignKey: (NSNotification *)aNotification')
  kept=$(body "$m" 'static bool omacvm_resign_kept(void)')
  letgo=$(body "$m" 'static void omacvm_key_let_go(void)')
  back=$(body "$m" '- (void)handKeyBack')
  chk "the rules are included" grep -q '#include "ui/omacvm-key-handback.h"' "$m"
  chk "the resign asks first, and keeps nothing else" order "$resign" \
    'if (omacvm_resign_kept()) {' 'return;' 'omacvm_key_let_go();'
  chk "the resign lets go only through the old let-go" lacks "$resign" '[cocoaView ungrabMouse];'
  chk "the let-go is the old one: pointer_left, ungrab, keys up" order "$letgo" \
    'omacvm_pointer_left(&omacvm_ptr);' '[cocoaView ungrabMouse];' '[cocoaView raiseAllKeys];'
  chk "the event is the one AppKit handles" has "$kept" 'NSEvent *e = [NSApp currentEvent];'
  for t in NSEventTypeLeftMouseDown NSEventTypeRightMouseDown NSEventTypeOtherMouseDown; do
    chk "a click is a button going down: $t" has "$kept" "$t"
  done
  chk "in a head window (ours, not the main one)" has "$kept" \
    '.in_head = e && [e window] != main && omacvm_is_our_window([e window]),'
  chk "the main window on screen" has "$kept" '.main_visible = [main isVisible],'
  chk "its Space shown" has "$kept" '.main_space = [main isOnActiveSpace],'
  chk "QEMU in front" has "$kept" '.active = [NSApp isActive],'
  chk "the rules decide" has "$kept" 'if (!omacvm_handback_keep(&omacvm_handback, &in)) {'
  chk "on the next turn: the key must be back, else the let-go" order "$kept" \
    'dispatch_async(dispatch_get_main_queue(), ^{' \
    'if (omacvm_handback_settle(&omacvm_handback, [[cocoaView window] isKeyWindow])) {' 'omacvm_key_let_go();'
  chk "the debug log says so" has "$kept" 'key to another display'"'"'s window at a click: pointer and keys kept'
  chk "handKeyBack uses the same rule" has "$back" \
    'if (omacvm_handback_ok([main isVisible], [main isOnActiveSpace], [NSApp isActive],'
  chk "the resign is kept only from windowDidResignKey:" \
    test "$(grep -c 'omacvm_resign_kept()' "$m")" = 1
}
# What must stay as it was (passes before and after the patch).
same() {
  local m=$1 cap init down rdown odown
  cap=$(body "$m" '- (BOOL) isKeyboardCaptured')
  init=$(body "$m" 'static void omacvm_displays_init(void)')
  down=$(body "$m" '- (void)mouseDown:(NSEvent *)e')
  rdown=$(body "$m" '- (void)rightMouseDown:(NSEvent *)e')
  odown=$(body "$m" '- (void)otherMouseDown:(NSEvent *)e')
  chk "isKeyboardCaptured as before" has "$cap" '(full_grab_enabled && omacvm_is_our_window([NSApp keyWindow]));'
  chk "another app in front still lets go" order "$init" \
    'addObserverForName:NSApplicationDidResignActiveNotification' 'omacvm_pointer_left(&omacvm_ptr);' '[cocoaView ungrabMouse];'
  for b in "$down" "$rdown" "$odown"; do
    chk "a click in a head window hands the key back before the VM gets it" order "$b" \
      '[self handKeyBack];' '[self send:e button:'
  done
  chk "handKeyBack only while the main window's Space shows" has "$(body "$m" '- (void)handKeyBack')" '[main isOnActiveSpace]'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-key-handback.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf -- '- (void) windowDidResignKey: (NSNotification *)aNotification\n{\n    COCOA_DEBUG("%%s\\n", __func__);\n'
      printf '    omacvm_pointer_left(&omacvm_ptr);\n    [cocoaView ungrabMouse];\n    [cocoaView raiseAllKeys];\n}\n'
      printf -- '- (void)handKeyBack\n{\n    NSWindow *main = [cocoaView window];\n'
      printf '    if ([main isVisible] && [main isOnActiveSpace] && [NSApp isActive] && ![main isKeyWindow]) {\n'
      printf '        [main makeKeyWindow];\n    }\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$( { checks "$1"; same "$1"; } | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-key-handback: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-key-handback: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-key-handback.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-key-handback-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-key-handback.c" -o "$work/test-key-handback"
"$work/test-key-handback"
