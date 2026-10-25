#!/bin/bash
# OmacVM's VA driver shim and Chromium's surfaces (omacvm_drv_video.c, "Surfaces with
# their real size"): which surfaces get the export hint, in which processes, and only
# when the Mac's runtime says omacvm.vaexport=1. The shim runs against a stand-in for
# Mesa's driver (va-shim-surfaces.c), on Linux with libva's headers (libva-dev).
#   src/app/guest/tests/va-shim-surfaces.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-surfaces.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl || exit 1
cc -O2 -Wall -o "$T/va-shim-surfaces" "$here/va-shim-surfaces.c" -ldl || exit 1
printf 'OMACVM_VKWINDOWS=1\nOMACVM_VAEXPORT=1\n' > "$T/host-new.env"
printf 'OMACVM_VKWINDOWS=1\n' > "$T/host-old.env"
printf 'OMACVM_VKWINDOWS=1\nOMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\n' > "$T/host-async.env"

# run WHAT EXPECT [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...).
run() {
  local what=$1 expect=$2 out
  shift 2
  out=$(env -i PATH="$PATH" $what "$T/va-shim-surfaces" "$T/shim.so" "$T/stub.so" "$expect" "$@" 2>&1)
  if [[ $? == 0 ]]; then
    echo "ok: $what ${*:-} -> hint $expect"
  else
    echo "FAIL: $what ${*:-} (hint expected: $expect)"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
run "OMACVM_VA_EXPORT=1" yes
run "OMACVM_VA_EXPORT=0" no --type=gpu-process
run "OMACVM_VA_EXPORT=0 OMACVM_HOST_ENV=$T/host-new.env" no --type=gpu-process
# Chromium's GPU and decoder processes (--type=) on a runtime that draws the frames.
run "OMACVM_HOST_ENV=$T/host-new.env" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-new.env" yes --type=utility
# Not Chromium (mpv, FFmpeg, Firefox): Mesa's surfaces as they are.
run "OMACVM_HOST_ENV=$T/host-new.env" no
# An older runtime shows the converted frames black: Chromium decodes on the CPU.
run "OMACVM_HOST_ENV=$T/host-old.env" no --type=gpu-process
run "OMACVM_HOST_ENV=$T/none.env" no --type=gpu-process
# The size limit for Chromium's hardware decoding (decoding configs only): off, and another one.
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_MAX=0" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_MAX=3840" yes --type=gpu-process
# Not a number: the default limit; too large for an int: no limit (not a negative one).
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_MAX=abc" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_MAX=4294967295" yes --type=gpu-process
# The export hint forced in Chromium: the limit too (forced elsewhere, as above: none).
run "OMACVM_VA_EXPORT=1 OMACVM_HOST_ENV=$T/none.env" yes --type=gpu-process
# A runtime that decodes beside its GPU thread: no limit unless OMACVM_VA_MAX says one.
run "OMACVM_HOST_ENV=$T/host-async.env WANT_DEFAULT_MAX=0" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-async.env WANT_DEFAULT_MAX=0 OMACVM_VA_MAX=abc" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-async.env OMACVM_VA_MAX=1920" yes --type=gpu-process

# The app says so at every start (Runner.swift), as host.env's reader expects.
if grep -q '^        a += \["-smbios", "type=11,value=omacvm.vaexport=1"\]$' "$repo/app/app/Sources/OmacVM/Runner.swift"; then
  echo "ok: the app always sends omacvm.vaexport"
else
  echo "FAIL: Runner.swift does not always send omacvm.vaexport"; fail=1
fi
(( fail )) && { echo "va-shim-surfaces: FAILED"; exit 1; }
echo "va-shim-surfaces: all ok"
