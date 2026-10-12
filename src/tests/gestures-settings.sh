#!/bin/bash
# omacvm gestures (src/cmd/gestures.sh) in a throwaway settings domain: the
# defaults, each change, the values Gestures, the app window and the Bridge
# read (EscapeSwipe pointer|all, SwipeOut bool, MouseSwipeFingers 3|4), odd
# stored values read as Gestures reads them, usage errors. No Mac helper runs.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
export OMACVM_GESTURES_DOMAIN=org.omacvm.test.gestures-settings.$$
trap 'defaults delete "$OMACVM_GESTURES_DOMAIN" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$OMACVM_GESTURES_DOMAIN.plist"' EXIT
fail=0
t() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$3', want '$2'"; fail=1; fi; }
g() { "$R/omacvm" gestures "$@" 2>&1; }
t "fresh: the defaults" '{"escape": "pointer", "swipe_out": false, "mouse_swipe": 4, "changed": false}' "$(g --json)"
t "escape all" '{"escape": "all", "swipe_out": false, "mouse_swipe": 4, "changed": true}' "$(g escape all --json)"
t "  stored as the app and Gestures read it" all "$(defaults read "$OMACVM_GESTURES_DOMAIN" EscapeSwipe)"
t "  again: unchanged" false "$(g escape all --json | sed 's/.*"changed": \([a-z]*\).*/\1/')"
t "swipe-out on, mouse-swipe 3 at once" '{"escape": "all", "swipe_out": true, "mouse_swipe": 3, "changed": true}' "$(g swipe-out on mouse-swipe 3 --json)"
t "  SwipeOut a bool" 1 "$(defaults read "$OMACVM_GESTURES_DOMAIN" SwipeOut)"
t "  MouseSwipeFingers a number" 3 "$(defaults read "$OMACVM_GESTURES_DOMAIN" MouseSwipeFingers)"
out=$(g); [[ $out == *"Escape combo (⌃⌥ Esc): all monitors"* && $out == *"Swipe out to macOS: on"* && $out == *"Magic Mouse swipe: 3 fingers"* ]] &&
  echo "ok   the plain words" || { echo "FAIL plain: $out"; fail=1; }
t "escape display (an alias): this monitor" pointer "$(g escape display --json | sed 's/.*"escape": "\([a-z]*\)".*/\1/')"
t "  stored as pointer" pointer "$(defaults read "$OMACVM_GESTURES_DOMAIN" EscapeSwipe)"
defaults write "$OMACVM_GESTURES_DOMAIN" EscapeSwipe -string ALL
defaults write "$OMACVM_GESTURES_DOMAIN" SwipeOut -string yes
t "odd stored values read as Gestures does (ALL, yes)" '{"escape": "all", "swipe_out": true, "mouse_swipe": 3, "changed": false}' "$(g --json)"
g escape sideways >/dev/null; t "escape sideways: usage" 2 "$?"
g swipe-out maybe >/dev/null; t "swipe-out maybe: usage" 2 "$?"
g mouse-swipe 5 >/dev/null; t "mouse-swipe 5: usage" 2 "$?"
g --vm x >/dev/null; t "no --vm (the Mac's own)" 2 "$?"
exit $fail
