#!/bin/bash
# The size of QEMU's SDL playback buffers for the Mac's output (#548):
# qemu-sdl-audio-out-size-logic.patch makes audio/omacvm-sdl-out-size.h in
# an empty folder and test-out-size.c runs against it. With audio/sdlaudio.c
# as argument (the runtime build, after qemu-sdl-audio-out-size.patch): also
# that the playback open uses the rules.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-out-size.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/qemu-sdl-audio-out-size-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/audio" "$here/test-out-size.c" -o "$work/test-out-size"
"$work/test-out-size"

(( $# )) || exit 0
s=$1
fail() { echo "test-out-size: $s: $*" >&2; exit 1; }
body() { awk -v h="$1" 'index($0, h) == 1 && !/;$/ {on=1} on {print} on && /^}$/ {exit}' "$s"; }
grep -q '#include "omacvm-sdl-out-size.h"' "$s" || fail "the rules are not included"
open=$(body 'static void *sdl_out_open_thread(void *opaque)')
start=$(body 'static void sdl_out_start_open_closing(SDLVoiceOut *sdl, char *device_name,')
want=$(body 'static unsigned sdl_out_want(SDLVoiceOut *sdl)')
route=$(body 'static void sdl_refresh_route_Out(SDLVoiceOut *sdl)')
[[ -n $open && -n $start && -n $want && -n $route ]] || fail "a piece of the wiring is missing"
# A refused start tries the next size on the same open, at once.
grep -q 'omacvm_sdl_out_start_refused(' <<<"$open" && grep -q 'omacvm_sdl_out_next(' <<<"$open" ||
  fail "a refused start does not try a larger size"
# The old device is closed before the new size opens (SDL3 shares an open physical device).
awk '/SDL_CloseAudioDevice\(op->close_first\)/ && !c {c = NR} /sdl_open\(/ && !o {o = NR} END {exit !(c && o && c < o)}' <<<"$open" ||
  fail "a resize opens before the old device is closed"
# Every open is sized from the voice's size, the launcher's and a refused one.
grep -q 'omacvm_sdl_out_frames(' <<<"$want" && grep -q 'op->spec.samples = sdl_out_want(sdl);' <<<"$start" ||
  fail "the open is not sized"
# The launcher's size is followed while the device runs.
grep -q 'sdl_out_hint' <<<"$route" || fail "a change of the Mac's output is not followed"
echo "test-out-size: wiring ok"
