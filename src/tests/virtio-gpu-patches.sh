#!/bin/bash
# OmacVM's guest driver patches against real kernel sources: the files they
# change, as kernel.org has them (src/tests/virtio-gpu-src/v*/), patched in
# the builder's order (deep colour, the cursor plane, the damage fix, the HDR
# output metadata) with
# patch --dry-run first and no fuzz. A patch that stops fitting a kernel shows
# here, not first in a VM (where the builder leaves it out of that kernel's
# build). The order is checked against omacvm-virtio-gpu-build, and its own
# patch step must refuse a hunk that fits only with fuzz, still apply every mix
# of patches it can fall back to, and every hunk has as many context lines
# before its change as after (GNU patch with -F 0 pins an uneven hunk to the
# start or end of the file, so it would fail on every kernel).
#   src/tests/virtio-gpu-patches.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/app/guest/virtio-gpu
S=$R/src/tests/virtio-gpu-src
T=$(mktemp -d "${TMPDIR:-/tmp}/virtio-gpu-patches.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
order=(linux-virtio-gpu-deep-color.patch linux-virtio-gpu-cursor-plane.patch linux-virtio-gpu-damage-clips.patch
       linux-virtio-gpu-hdr-metadata.patch)

# The builder's order: deep colour first, then the others in its loop.
loop=$(grep -m1 -E '^  for p in "\$cursor_file"' "$G/omacvm-virtio-gpu-build")
if [[ $loop == '  for p in "$cursor_file" "$damage_file" "$meta_file"; do' ]]; then echo "ok   the builder's order: deep colour, cursor plane, damage fix, HDR metadata"
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
     grep -rq 'module_param_named(cursor_plane' "$T/$v/drivers/gpu/drm/virtio/" &&
     grep -A1 'vgdev->has_virgl_3d && virtio_gpu_deep_color)$' "$T/$v/drivers/gpu/drm/virtio/virtgpu_display.c" |
       grep -q 'drm_connector_attach_hdr_output_metadata_property(connector);'; then
    echo "ok   $v: all four apply in order, no fuzz; the HDR metadata only with virgl 3D and deep_color"
  else
    echo "FAIL $v: applied, but a patch's change is missing"; fail=1
  fi
  # Every output keeps its cursor plane (#554: aquamarine takes a cursor for an
  # output without one and shows nothing, so Hyprland drew no pointer there).
  disp=$T/$v/drivers/gpu/drm/virtio/virtgpu_display.c
  if grep -q 'cursor = virtio_gpu_plane_init(vgdev, DRM_PLANE_TYPE_CURSOR, index);' "$disp" &&
     ! grep -q 'virtio_gpu_cursor_plane' "$disp"; then
    echo "ok   $v: a cursor plane on every output, with or without cursor_plane"
  else
    echo "FAIL $v: some outputs get no cursor plane: $(grep -n 'virtio_gpu_cursor_plane\|DRM_PLANE_TYPE_CURSOR' "$disp" | tr '\n' ' ')"; fail=1
  fi
done
(( n >= 2 )) || { echo "FAIL fewer than two kernel versions in $S"; fail=1; }

# Even context: as many lines before each hunk's change as after it.
for p in "${order[@]}"; do
  odd=$(awk '
    /^@@ / { split($2, o, ","); split($3, m, ","); ol = (o[2] == "" ? 1 : o[2]); nl = (m[2] == "" ? 1 : m[2])
             hdr = $0; lead = 0; trail = 0; seen = 0; inh = 1; next }
    inh { c = substr($0, 1, 1)
          if (c == "\\") next
          if (c == " " || $0 == "") { ol--; nl--; if (seen) trail++; else lead++ }
          else if (c == "-") { ol--; seen = 1; trail = 0 }
          else if (c == "+") { nl--; seen = 1; trail = 0 }
          if (ol <= 0 && nl <= 0) { inh = 0; if (lead != trail) print hdr " (" lead " before, " trail " after)" } }
  ' "$G/$p")
  if [[ -z $odd ]] && grep -q '^@@ ' "$G/$p"; then echo "ok   $p: every hunk has even context"
  else printf 'FAIL %s: uneven context (GNU patch -F 0 would refuse it): %s\n' "$p" "${odd:-no hunks}"; fail=1; fi
done

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
  # Every mix the builder can fall back to (deep colour first), on each
  # kernel, through its own tree().
  deep=$G/${order[0]} cur=$G/${order[1]} dmg=$G/${order[2]} meta=$G/${order[3]}
  for d in "$S"/v*/; do
    v=$(basename "$d") M=$T/mix-$v
    mkdir -p "$M" && rm -rf "${M:?}/stock" && cp -R "$d/drivers" "$M/stock"
    for mix in "deep" "deep cur" "deep dmg" "deep meta" "deep cur dmg" "deep cur meta" "deep dmg meta" "deep cur dmg meta"; do
      files=()
      for k in $mix; do files+=("${!k}"); done
      if tree "$M" "${files[@]}" > /dev/null 2>&1; then echo "ok   builder on $v: $mix"
      else echo "FAIL builder on $v: $mix does not apply"; fail=1; fi
    done
  done
else
  echo "FAIL no tree() in omacvm-virtio-gpu-build (update this test)"; fail=1
fi
exit $fail
