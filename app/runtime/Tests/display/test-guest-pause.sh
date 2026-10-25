#!/bin/bash
# Pause drawing while hidden (omacvm-cocoa-guest-pause-logic.patch,
# omacvm-cocoa-guest-pause.patch): the patch makes ui/omacvm-guest-pause.h in
# an empty folder and test-guest-pause.c runs against it. With ui/cocoa.m as
# argument (the runtime build, after the wiring patch): also that the window's
# occlusion and the lock feed it, the guest is told, and the present keeps the
# last picture while the guest's display is off.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-guest-pause.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-guest-pause-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-guest-pause.c" -o "$work/test-guest-pause"
"$work/test-guest-pause"

(( $# )) || exit 0
m=$1
fail() { echo "test-guest-pause: $m: $*" >&2; exit 1; }
body() { awk -v h="$1" 'index($0, h) == 1 && !/;$/ {on=1} on {print} on && /^}$/ {exit}' "$m"; }
seen=$(body '- (void)omacvmWindowSeen:(NSNotification *)note')
lock=$(body 'static void omacvm_ds_lock_changed(const char *why)')
update=$(body 'static void omacvm_gp_update(void)')
tell=$(body 'static void omacvm_gp_tell(OmacVMGpTell tell)')
fire=$(body 'static void omacvm_gp_fire(unsigned gen)')
sw=$(body 'static void omacvm_gp_read_switch(void)')
present=$(body 'static bool cocoa_gl_present(void)')
off=$(body 'static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)')
flush=$(body 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,')
hello=$(body 'static void omacvm_chan_line(NSData *data)')
init=$(body 'static void omacvm_displays_init(void)')
[[ -n $seen && -n $lock && -n $update && -n $tell && -n $fire && -n $sw && -n $present && -n $off && -n $flush &&
   -n $hello && -n $init ]] || fail "a piece of the wiring is missing"
grep -q '#include "ui/omacvm-guest-pause.h"' "$m" || fail "the rules are not included"
# What feeds it: the occlusion, the lock and sleep, the start.
grep -q 'omacvm_gp_update();' <<<"$seen" && grep -q 'omacvm_gp_update();' <<<"$lock" &&
  grep -q 'omacvm_gp_update();' <<<"$init" || fail "the window's state does not reach the rules"
# Seen = some of the window on screen and nobody locked out; OMACVM_PRESENT_HIDDEN draws anyway.
grep -q 'qatomic_read(&omacvm_window_seen) && !omacvm_ds_screen_locked' <<<"$update" &&
  grep -q '!omacvm_ds_asleep && !omacvm_ds_away && !omacvm_ds_test_locked' <<<"$update" &&
  grep -q 'getenv("OMACVM_PRESENT_HIDDEN")' <<<"$update" || fail "seen is not worked out as tested"
grep -q 'tell = omacvm_gp_feed(&omacvm_gp, omacvm_gp_switch == 1, seen, now);' <<<"$update" &&
  grep -q 'omacvm_gp_fire(gen)' <<<"$update" && grep -q 'tell = omacvm_gp_due(&omacvm_gp, CACurrentMediaTime());' <<<"$fire" &&
  grep -q 'gen != omacvm_gp_gen' <<<"$fire" || fail "the rules are not asked as tested"
# The switch: the app's key (live), else OMACVM_GUEST_PAUSE.
grep -q 'boolForKey:@"pauseWhileHidden"' <<<"$sw" && grep -q 'getenv("OMACVM_GUEST_PAUSE")' <<<"$sw" &&
  grep -q 'forKeyPath:@"pauseWhileHidden"' <<<"$update" || fail "the switch is not read as tested"
# The guest is told over the display channel, a restarted agent again.
grep -q '{\\"unseen\\":\[\\"Virtual-1\\"\]}' <<<"$tell" && grep -q '{\\"unseen\\":\[\]}' <<<"$tell" &&
  grep -q 'omacvm_chan_write' <<<"$tell" && grep -q 'omacvm_gp_hello();' <<<"$hello" || fail "the guest is not told"
# The present: after the unseen check, the last picture kept while the guest's display is off.
awk '/omacvm_frames_unseen\+\+;/ {a = NR} /if \(omacvm_gp_keep\(&omacvm_gp, gl_scanout_borrow != NULL, CACurrentMediaTime\(\)\)\) \{/ {b = NR}
     /if \(gl_scanout_borrow\) \{/ && !c {c = NR} END {exit !(a && b && c && a < b && b < c)}' <<<"$present" ||
  fail "the present does not keep the last picture before drawing without a scanout"
grep -q 'omacvm_gp_dark = true;' <<<"$off" && grep -q 'unsigned n = omacvm_gp_frame(&omacvm_gp);' <<<"$flush" &&
  grep -q 'omacvm: guest drawing: paused for' <<<"$flush" || fail "the guest's pause is not logged"
echo "test-guest-pause: $m: wiring ok"
