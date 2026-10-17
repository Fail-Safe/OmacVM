#!/bin/bash
# compute.sh [on|off] (as root, in an OmacVM.app VM): WebGPU and GPU compute on
# the VM's Vulkan, the feature gpu-compute (on by default). While the VM's
# Graphics gives it Vulkan: OpenCL (opencl.sh: the distro's rusticl on Zink),
# WebGPU in Chromium from its "Chromium (WebGPU)" entry and in Firefox
# (webgpu.sh). Off, or Graphics OpenGL: all of it goes; Vulkan itself stays as
# Graphics says. No argument: the feature's value in /etc/omacvm/env (on when
# the VM's record has none yet, as for a VM from before 3.1.20).
# Run by guest/install.sh's gpu-compute step and by omacvm graphics.
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
cd "$(dirname "$0")"
ENV=${OMACVM_ENV:-/etc/omacvm/env}
want=${1:-$(sed -n 's/^OMACVM_FEATURE_gpu_compute=//p' "$ENV" 2>/dev/null | tail -1)}
want=${want:-on}
[[ $want == on || $want == off ]] || { echo "usage: compute.sh [on|off]" >&2; exit 2; }
graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENV" 2>/dev/null | tail -1)
export OMACVM_GPU_COMPUTE=$want   # webgpu.sh --off keeps nothing of it when off
if [[ $want == on && $graphics == vulkan ]]; then
  rc=0
  ./opencl.sh || rc=1
  ./webgpu.sh || rc=1
  exit $rc
fi
./opencl.sh --off
./webgpu.sh --off
