#!/bin/bash
# HDR: the headroom the guest tone-maps into (ADR 0049,
# omacvm-cocoa-hdr-headroom-logic.patch, omacvm-cocoa-hdr-headroom.patch):
# the logic patch makes ui/omacvm-edr.h in an empty folder and
# test-hdr-headroom.c runs its rules. With ui/cocoa.m as argument (the
# runtime build, after the wiring patch): also that the patched file is
# wired as tested (and the checks catch code without it).
#   test-hdr-headroom.sh                       (CI)
#   test-hdr-headroom.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-headroom.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hdr-headroom-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-hdr-headroom.c" -o "$work/t" -lm
"$work/t"

bodyx() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 follow now
  follow=$(bodyx "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf)')
  # After omacvm-cocoa-extra-brightness.patch the commit thread also passes the frame's kind.
  [[ -n $follow ]] || follow=$(bodyx "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)')
  now=$(bodyx "$m" 'static double omacvm_edr_now(void)')
  grep -q '#include "ui/omacvm-edr.h"' "$m" || echo "ui/omacvm-edr.h is not used"
  grep -q 'setToneMapMode:hdr ? CAToneMapModeNever' <<<"$follow" || echo "macOS tone-maps the guest's PQ again"
  grep -q 'bool deep = ifmt == GL_RGB10_A2;' "$m" || echo "a float scanout is taken as PQ"
  grep -q 'present_deep_failed' <<<"$now" || echo "the guest is not told when PQ cannot be shown"
  grep -q 'omacvm_edr_value(\[s maximumExtendedDynamicRangeColorComponentValue\]' <<<"$now" ||
    echo "the headroom is not the window's display's"
  grep -q 'entry\[@"edr"\] = @(omacvm_edr_sent);' "$m" || echo "the layout does not carry the headroom"
  grep -q 'getenv("OMACVM_GL_EDR")' "$m" || echo "the app's switch (OMACVM_GL_EDR) is not read"
  grep -q 'PRESENT_REALLOC_NS && !depth_now' "$m" || echo "a new depth waits for the hold-off (wrong colours at first)"
}

# The checks catch code without it (3.1.24's colour patch).
cat > "$work/old.m" <<'EOF2'
static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf)
{
    if ([layer wantsExtendedDynamicRangeContent] != hdr) {
        [layer setWantsExtendedDynamicRangeContent:hdr];
    }
}
    bool deep = ifmt == GL_RGB10_A2 || ifmt == GL_RGBA16F || ifmt == GL_RGB16F;
EOF2
old=$(problems "$work/old.m")
for want in "tone-maps the guest's PQ again" "float scanout" "not told" "does not carry"; do
  [[ $old == *"$want"* ]] || { echo "test-hdr-headroom: the checks miss the old code: $want" >&2; exit 1; }
done

(( $# )) || exit 0
m=$1
out=$(problems "$m")
if [[ -n $out ]]; then echo "test-hdr-headroom: $m: $out" >&2; exit 1; fi
echo "test-hdr-headroom: $m: wiring ok"
