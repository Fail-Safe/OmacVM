#!/bin/bash
# OmacVM's guest driver patches against real kernel sources: the files they
# change, as kernel.org has them (src/tests/virtio-gpu-src/v*/), patched in
# the builder's order (deep colour, the cursor plane, the vsync lock, the damage fix) with
# patch --dry-run first and no fuzz. A patch that stops fitting a kernel shows
# here, not first in a VM (where the builder leaves it out of that kernel's
# build). The order is checked against omacvm-virtio-gpu-build, and its own
# patch step must refuse a hunk that fits only with fuzz.
#   src/tests/virtio-gpu-patches.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/app/guest/virtio-gpu
S=$R/src/tests/virtio-gpu-src
T=$(mktemp -d "${TMPDIR:-/tmp}/virtio-gpu-patches.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
order=(linux-virtio-gpu-deep-color.patch linux-virtio-gpu-cursor-plane.patch linux-virtio-gpu-vsync-lock.patch linux-virtio-gpu-damage-clips.patch)

# The builder's order: deep colour first, then the others in its loop.
loop=$(grep -m1 -E '^  for p in "\$cursor_file"' "$G/omacvm-virtio-gpu-build")
if [[ $loop == '  for p in "$cursor_file" "$vsync_file" "$damage_file"; do' ]]; then echo "ok   the builder's order: deep colour, cursor plane, vsync lock, damage fix"
else echo "FAIL the builder's order changed: '$loop' (update this test's order)"; fail=1; fi

n=0
for d in "$S"/v*/; do
  v=$(basename "$d"); n=$((n + 1))
  rm -rf "${T:?}/$v" && cp -R "$d" "$T/$v"
  for p in "${order[@]}"; do
    if ! out=$(patch -p1 -F 0 -s --dry-run -d "$T/$v" -i "$G/$p" 2>&1); then
      printf 'FAIL %s: %s does not apply (after the ones before it)\n%s\n' "$v" "$p" "$out"; fail=1; continue 2
    fi
    patch -p1 -F 0 -s -d "$T/$v" -i "$G/$p" > /dev/null 2>&1 || { echo "FAIL $v: $p dry run ok, real run not"; fail=1; continue 2; }
  done
  # Applied: the damage fix's line and the options are in.
  if grep -q 'old_plane_state->fb != new_plane_state->fb && bo->dumb;' "$T/$v/drivers/gpu/drm/virtio/virtgpu_plane.c" &&
     grep -rq 'module_param_named(deep_color' "$T/$v/drivers/gpu/drm/virtio/" &&
     grep -rq 'module_param_named(cursor_plane' "$T/$v/drivers/gpu/drm/virtio/"; then
    echo "ok   $v: all four apply in order, no fuzz"
  else
    echo "FAIL $v: applied, but a patch's change is missing"; fail=1
  fi
done
(( n >= 2 )) || { echo "FAIL fewer than two kernel versions in $S"; fail=1; }

# The builder's own patch step (its tree function, as it is): a hunk must fit
# exactly. One that fits only with fuzz (a context line differs) could land in
# the wrong place of a newer kernel, so it must fail: the builder then leaves
# that patch out, as one that does not apply. A hunk that fits exactly but a
# few lines further down (offset) still applies.
sed -n '/^tree() {/,/^}/p' "$G/omacvm-virtio-gpu-build" > "$T/tree.sh"
if grep -q '^tree() {' "$T/tree.sh"; then
  # shellcheck source=/dev/null
  source "$T/tree.sh"
  F=$T/fuzz; V=drivers/gpu/drm/virtio
  mkdir -p "$F/stock/gpu/drm/virtio"
  printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10 11 12 > "$F/stock/gpu/drm/virtio/f.c"
  hunk() {   # FIRST-CONTEXT-LINE: a patch that changes line 6, context lines 3-5 and 7-9
    printf -- '--- a/%s/f.c\n+++ b/%s/f.c\n@@ -3,7 +3,7 @@\n %s\n line 4\n line 5\n-line 6\n+line six\n line 7\n line 8\n line 9\n' "$V" "$V" "$1"
  }
  hunk 'line 3' > "$T/exact.patch"
  hunk 'line three' > "$T/fuzzy.patch"
  if tree "$F" "$T/exact.patch" > /dev/null 2>&1 && grep -qx 'line six' "$F/$V/f.c"; then
    echo "ok   builder: a hunk that fits exactly applies"
  else echo "FAIL builder: a hunk that fits exactly does not apply"; fail=1; fi
  if tree "$F" "$T/fuzzy.patch" > /dev/null 2>&1; then
    echo "FAIL builder: a hunk that fits only with fuzz applies (it could land in the wrong place)"; fail=1
  else echo "ok   builder: a hunk that fits only with fuzz does not apply (the patch is left out)"; fi
  printf 'line 0\n' | cat - "$F/stock/gpu/drm/virtio/f.c" > "$T/f.c" && printf 'line -1\n' | cat - "$T/f.c" > "$F/stock/gpu/drm/virtio/f.c"
  if tree "$F" "$T/exact.patch" > /dev/null 2>&1 && grep -qx 'line six' "$F/$V/f.c"; then
    echo "ok   builder: an exact hunk two lines further down still applies"
  else echo "FAIL builder: an exact hunk two lines further down does not apply"; fail=1; fi
else
  echo "FAIL no tree() in omacvm-virtio-gpu-build (update this test)"; fail=1
fi
exit $fail
