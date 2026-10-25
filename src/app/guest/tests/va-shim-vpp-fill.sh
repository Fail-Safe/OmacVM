#!/bin/bash
# OmacVM's VA driver shim and Chrome's call tiles (omacvm_drv_video.c, "Chromium's RGB frames fill
# their planes"): ARGB imports at the rounded size when their buffer holds it, the video processing
# regions Mesa gets, only in Chromium's processes and only with a Mesa the fill was checked with. The shim runs against a stand-in for Mesa's
# driver (va-shim-vpp-fill.c), on Linux with libva's headers (libva-dev).
#   src/app/guest/tests/va-shim-vpp-fill.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-vpp-fill.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl || exit 1
cc -O2 -Wall -o "$T/va-shim-vpp-fill" "$here/va-shim-vpp-fill.c" -ldl || exit 1

# run WHAT EXPECT [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...).
run() {
  local what=$1 expect=$2 out
  shift 2
  out=$(env -i PATH="$PATH" OMACVM_HOST_ENV="$T/none.env" $what "$T/va-shim-vpp-fill" "$T/shim.so" "$T/stub.so" "$expect" "$@" 2>&1)
  if [[ $? == 0 ]]; then
    echo "ok: $what ${*:-} -> rewritten: $expect"
  else
    echo "FAIL: $what ${*:-} (rewritten expected: $expect)"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
# Chromium's GPU and decoder processes.
run "" yes --type=gpu-process
run "" yes --type=utility
# Not Chromium (mpv, FFmpeg's scale_vaapi, Firefox), or switched off: as the app gave it.
run "" no
run "OMACVM_VA_FILL=0" no --type=gpu-process
run "OMACVM_VA_FILL=1" yes
# A Mesa newer than the one the fill was checked with: off (logged), unless switched on.
run "STUB_MESA=26.3.0" no --type=gpu-process
run "STUB_MESA=26.3.0 OMACVM_VA_FILL=1" yes --type=gpu-process
run "STUB_MESA=25.1.4" yes --type=gpu-process
(( fail )) && { echo "va-shim-vpp-fill: FAILED"; exit 1; }
echo "va-shim-vpp-fill: all ok"
