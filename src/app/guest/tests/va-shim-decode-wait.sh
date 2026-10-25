#!/bin/bash
# OmacVM's VA driver shim waits for the Mac's media engine after vaEndPicture in Chromium
# (omacvm_drv_video.c, "Waiting for the picture"): only on decoding contexts, only when the
# Mac's runtime says omacvm.vadecasync=1, at most about 100 ms. The shim runs against a
# stand-in for Mesa's driver and for the kernel's EXECBUFFER (va-shim-decode-wait.c), on
# Linux with libva's headers (libva-dev) and the kernel's (linux-libc-dev).
#   src/app/guest/tests/va-shim-decode-wait.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-decode-wait.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl || exit 1
cc -O2 -Wall -rdynamic -o "$T/va-shim-decode-wait" "$here/va-shim-decode-wait.c" -ldl -lpthread || exit 1
printf 'OMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\n' > "$T/host-new.env"
printf 'OMACVM_VAEXPORT=1\n' > "$T/host-old.env"

# run WHAT EXPECT [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...).
run() {
  local what=$1 expect=$2 out
  shift 2
  out=$(env -i PATH="$PATH" $what "$T/va-shim-decode-wait" "$T/shim.so" "$T/stub.so" "$expect" "$@" 2>&1)
  if [[ $? == 0 ]]; then
    echo "ok: $what ${*:-} -> waits: $expect"
  else
    echo "FAIL: $what ${*:-} (waits expected: $expect)"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
# Chromium's GPU and decoder processes on a runtime that decodes beside its GPU thread.
run "OMACVM_HOST_ENV=$T/host-new.env" yes --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-new.env" yes --type=utility
# Not Chromium (mpv, FFmpeg, Firefox), or an older runtime (it waits itself): nothing.
run "OMACVM_HOST_ENV=$T/host-new.env" no
run "OMACVM_HOST_ENV=$T/host-old.env" no --type=gpu-process
run "OMACVM_HOST_ENV=$T/none.env" no --type=gpu-process
# Overrides.
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_DECODE_WAIT=0" no --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-old.env OMACVM_VA_DECODE_WAIT=1" yes

# The app says so at every start (Runner.swift), as host.env's reader expects, unless QEMU
# waits for each picture (OMACVM_VIDEO_DECODE_SYNC=1): then the guest is as in 3.2.0 too.
runner=$repo/app/app/Sources/OmacVM/Runner.swift
if grep -A1 -F 'if ProcessInfo.processInfo.environment["OMACVM_VIDEO_DECODE_SYNC"] != "1" {' "$runner" |
   grep -q '^            a += \["-smbios", "type=11,value=omacvm.vadecasync=1"\]$' &&
   [[ $(grep -c 'omacvm.vadecasync=1' "$runner") == 1 ]]; then
  echo "ok: the app sends omacvm.vadecasync unless OMACVM_VIDEO_DECODE_SYNC=1"
else
  echo "FAIL: Runner.swift does not send omacvm.vadecasync only without OMACVM_VIDEO_DECODE_SYNC=1"; fail=1
fi
(( fail )) && { echo "va-shim-decode-wait: FAILED"; exit 1; }
echo "va-shim-decode-wait: all ok"
