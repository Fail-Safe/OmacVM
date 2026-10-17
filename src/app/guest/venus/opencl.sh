#!/bin/bash
# opencl.sh (as root, in an OmacVM.app VM): OpenCL on the Mac's GPU for a VM
# whose Graphics setting gives it Vulkan (feature gpu-compute: compute.sh runs
# this). The distro's rusticl (opencl-mesa) runs on Zink, which runs on Venus:
# no build, pacman installs and removes it. It works where the Mac's Vulkan
# driver is KosmicKrisp (OmacVM.app on macOS 26+). On MoltenVK (macOS 15) Zink
# refuses the device ("requires the nullDescriptor feature of robustness2"):
# there the feature vulkan's Mesa (venus/install.sh, with its MoltenVK
# patches) is the way.
#   opencl.sh          install opencl-mesa + clinfo, turn rusticl's Zink on
#   opencl.sh --check  turn it off again when Zink lists no GPU device now
#                      (after each boot: omacvm-venus-driver.service)
#   opencl.sh --off    turn it off (the VM has OpenGL only, or gpu-compute off)
# Rusticl only lists drivers named in RUSTICL_ENABLE, so the switch is what
# gives apps the device; the package stays (pacman -Rns opencl-mesa removes it).
# A Mac whose Vulkan driver Zink refuses gets no switch (apps fall back to the
# CPU instead of an OpenCL platform without a device); the reason is kept for
# omacvm check. Checked at run time, never by Mac model (STANDARDS 16).
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
ENVF=${OMACVM_OPENCL_ENV:-/etc/environment.d/90-omacvm-opencl.conf}
OURS=${OMACVM_MESA_CLICD:-/etc/OpenCL/vendors/omacvm-rusticl.icd}
OFF=${OMACVM_OPENCL_OFF:-/var/lib/omacvm/opencl-off}   # why OpenCL is off on this Mac's Vulkan driver
HERE=$(cd "$(dirname "$0")" && pwd)

# Zink's device on this start's Venus: 0 listed, 1 none (OFF says why), 2 no Venus now (not known yet).
zink_device() {
  "${OMACVM_VENUS_ON:-$HERE/install.sh}" --venus-on || return 2
  local out
  out=$(RUSTICL_ENABLE=zink ZINK_DEBUG=quiet "${OMACVM_CLINFO:-clinfo}" -l 2>&1) || true
  grep -q 'zink' <<<"$out" && return 0
  mkdir -p "$(dirname "$OFF")"
  echo "Zink lists no GPU device on this Mac's Vulkan driver$(grep -m1 -o 'requires the [A-Za-z]* feature[^.]*' <<<"$out" | sed 's/^/ (/; s/$/)/')" > "$OFF"
  return 1
}
off_for_mac() { rm -f "$ENVF"; echo "OpenCL: off: $(cat "$OFF") (on MoltenVK, macOS 15: omacvm enable vulkan)"; }

case ${1:-} in
  --off) rm -f "$ENVF" "$OFF"; exit 0 ;;
  --check)
    [[ -f $ENVF ]] || exit 0
    rc=0; zink_device || rc=$?
    case $rc in 0) rm -f "$OFF" ;; 1) off_for_mac ;; esac
    exit 0 ;;
  "") ;;
  *) echo "usage: opencl.sh [--check | --off]" >&2; exit 2 ;;
esac
# The vulkan feature's Mesa brings its own rusticl and switch.
if [[ -f $OURS ]]; then rm -f "$ENVF" "$OFF"; echo "OpenCL: OmacVM's Mesa (feature vulkan)"; exit 0; fi
(( EUID == 0 )) || { echo "opencl.sh: run as root" >&2; exit 1; }
"${OMACVM_PKG_ADD:-$HERE/../../../guest/pkg-add}" opencl-mesa clinfo ||
  { echo "OpenCL: opencl-mesa not installed (see above)" >&2; exit 1; }
mkdir -p "$(dirname "$ENVF")"
# ZINK_DEBUG=quiet: Zink's "Some incorrect rendering might occur ..." line on
# every start (KosmicKrisp has no VK_EXT_custom_border_color); Mesa documents
# the flag as "suppress probably-harmless warnings" (docs/drivers/zink.rst).
printf 'RUSTICL_ENABLE=zink\nZINK_DEBUG=quiet\n' > "$ENVF"
rc=0; zink_device || rc=$?
case $rc in
  0) rm -f "$OFF"; echo "OpenCL: rusticl on Zink (Vulkan) for apps started after the next login" ;;
  1) off_for_mac ;;
  2) rm -f "$OFF"; echo "OpenCL: rusticl on Zink (Vulkan) from the VM's next start (checked then)" ;;
esac
