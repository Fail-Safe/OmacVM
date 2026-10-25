#!/bin/bash
# OmacVM's guest driver patches against real kernel sources: the files they
# change, as kernel.org has them (src/tests/virtio-gpu-src/v*/), patched in
# the builder's order (deep colour, the cursor plane, the damage fix) with
# patch --dry-run first and no fuzz. A patch that stops fitting a kernel shows
# here, not first in a VM (where the builder leaves it out of that kernel's
# build). The order is checked against omacvm-virtio-gpu-build.
#   src/tests/virtio-gpu-patches.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/app/guest/virtio-gpu
S=$R/src/tests/virtio-gpu-src
T=$(mktemp -d "${TMPDIR:-/tmp}/virtio-gpu-patches.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
order=(linux-virtio-gpu-deep-color.patch linux-virtio-gpu-cursor-plane.patch linux-virtio-gpu-damage-clips.patch)

# The builder's order: deep colour first, then the others in its loop.
loop=$(grep -m1 -E '^  for p in "\$cursor_file"' "$G/omacvm-virtio-gpu-build")
if [[ $loop == '  for p in "$cursor_file" "$damage_file"; do' ]]; then echo "ok   the builder's order: deep colour, cursor plane, damage fix"
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
    echo "ok   $v: all three apply in order, no fuzz"
  else
    echo "FAIL $v: applied, but a patch's change is missing"; fail=1
  fi
done
(( n >= 2 )) || { echo "FAIL fewer than two kernel versions in $S"; fail=1; }
exit $fail
