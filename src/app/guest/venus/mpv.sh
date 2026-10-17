#!/bin/bash
# mpv.sh (as root, in an OmacVM.app VM): mpv draws with OpenGL while the VM has
# Vulkan. mpv picks Vulkan by itself whenever the VM has a Vulkan driver
# (gpu-api=auto -> waylandvk), and on Venus it shows no video at all (Mac mini
# M4, KosmicKrisp, 2026-10-17: stuck after its first frames in every swap
# mode). OpenGL (virgl) plays it. The system-wide mpv.conf gets gpu-api=opengl
# in a marked block; mpv reads the user's ~/.config/mpv/mpv.conf after it, so a
# gpu-api line there wins.
#   mpv.sh          add the block (Graphics Vulkan or the vulkan feature)
#   mpv.sh --off    remove it, unless the VM still has Vulkan another way
# The rest of the file is left as it is; a file that held only the block goes.
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
DEST=${OMACVM_MPV_ROOT:-}
CONF=$DEST/etc/mpv/mpv.conf
ENVF=$DEST/etc/omacvm/env
OURS=$DEST/etc/vulkan/icd.d/omacvm_venus_icd.json
BEGIN='# OmacVM: begin (mpv shows no video on Venus yet; a gpu-api line in ~/.config/mpv/mpv.conf wins)'
END='# OmacVM: end'

strip() {   # the file without our block
  [[ -f $CONF ]] || return 0
  awk -v e="$END" 'index($0, "# OmacVM: begin") == 1 { s = 1; next } s && $0 == e { s = 0; next } !s' "$CONF" > "$CONF.omacvm"
  if grep -q '[^[:space:]]' "$CONF.omacvm"; then mv "$CONF.omacvm" "$CONF"; else rm -f "$CONF.omacvm" "$CONF"; fi
}

case ${1:-} in
  --off)
    graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENVF" 2>/dev/null | tail -1)
    feature=$(sed -n 's/^OMACVM_FEATURE_vulkan=//p' "$ENVF" 2>/dev/null | tail -1)
    [[ $graphics == vulkan || $feature == on || -f $OURS ]] && exit 0
    strip
    exit 0 ;;
  "") ;;
  *) echo "usage: mpv.sh [--off]" >&2; exit 2 ;;
esac
[[ -n $DEST ]] || (( EUID == 0 )) || { echo "mpv.sh: run as root" >&2; exit 1; }
strip
mkdir -p "$(dirname "$CONF")"
printf '%s\ngpu-api=opengl\n%s\n' "$BEGIN" "$END" >> "$CONF"
echo "mpv: OpenGL (it shows no video on Vulkan here yet; ~/.config/mpv/mpv.conf can choose)"
