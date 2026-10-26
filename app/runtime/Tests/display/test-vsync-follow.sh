#!/bin/bash
# The guest's vblanks follow the Mac's refresh (omacvm-vsync-follow-logic.patch,
# omacvm-vsync-follow.patch): the logic patch makes ui/omacvm-vsync.h in an
# empty folder and test-vsync-follow.c runs its rules. With the patched QEMU
# source folder as argument (the runtime build, after the wiring patch): also
# that it is wired as tested (and the checks catch a tree without it).
#   test-vsync-follow.sh                    (CI)
#   test-vsync-follow.sh <patched QEMU dir> (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vsync-follow.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-vsync-follow-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-vsync-follow.c" -o "$work/t" -lm
"$work/t"

problems() {   # QEMU source folder
  local m=$1/ui/cocoa.m g=$1/hw/display/virtio-gpu-virgl.c h=$1/target/arm/hvf/hvf.c
  grep -q '#include "ui/omacvm-vsync.h"' "$m" 2>/dev/null || echo "ui/cocoa.m does not use ui/omacvm-vsync.h"
  grep -q 'omacvm_vsync_publish((int64_t)llround(present_sync.grid_vblank \* 1e9), ps);' "$m" 2>/dev/null ||
    echo "the display link does not give the grid to the guest"
  grep -q 'omacvm_lead_clamp(present_sync.follow_lead, present_sync.grid_period);' "$m" 2>/dev/null ||
    echo "the guest's vblank is not the lead (within its limits) before the commit"
  grep -q 'omacvm_lead_frame(&present_sync.lead, now, present_sync.ans_vblank,' "$m" 2>/dev/null ||
    echo "the lead does not follow when the guest's frames are ready"
  grep -q 'bool follow = asked && omacvm_vsync_locked();' "$m" 2>/dev/null ||
    echo "frames count as in step without the guest saying so"
  grep -q 'omacvm_vsync_grid_fresh(now, vsync_published_ns);' "$1/ui/omacvm-vsync.c" 2>/dev/null ||
    echo "an old grid is handed to the guest"
  grep -q 'omacvm_vsync_for_guest(le32_to_cpu(req.flags), le32_to_cpu(req.version),' "$g" 2>/dev/null ||
    echo "virtio-gpu does not pass the guest's ask on"
  grep -q '(input || (present_sync.follow && !present_sync.follow_buffered))' "$m" 2>/dev/null ||
    echo "a late frame waits a refresh while the guest follows"
  grep -q 'present_sync.follow_buffered = omacvm_follow_buffered(&present_sync.lead,' "$m" 2>/dev/null ||
    echo "late frames are dropped even when the guest's frames are too slow to follow"
  grep -q 'case OMACVM_VIRTIO_GPU_CMD_VSYNC:' "$g" 2>/dev/null || echo "virtio-gpu does not answer the guest"
  [[ $(grep -c 'omacvm_vsync_set_counter_offset(hvf_state->vtimer_offset);' "$h" 2>/dev/null) == 2 ]] ||
    echo "hvf does not give the guest counter's offset (start and resume)"
}

# The checks catch a tree without the wiring.
mkdir -p "$work/old/ui" "$work/old/hw/display" "$work/old/target/arm/hvf"
echo 'static bool cocoa_gl_present_vsync(double T)' > "$work/old/ui/cocoa.m"
: > "$work/old/hw/display/virtio-gpu-virgl.c"
: > "$work/old/target/arm/hvf/hvf.c"
[[ $(problems "$work/old" | wc -l) -ge 11 ]] || { echo "FAIL: the wiring checks pass without the patch"; exit 1; }

if (( $# )); then
  p=$(problems "$1")
  [[ -z $p ]] || { echo "FAIL: $p"; exit 1; }
  echo "ok   vsync follow: wired in $1"
fi
