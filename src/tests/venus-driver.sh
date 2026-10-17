#!/bin/bash
# Offline test of src/app/guest/venus (no VM): when an OmacVM.app VM gets the
# Venus driver built from Mesa 26.2.4 (with the WebGPU semaphore patch), and
# that the package, the installer and the check agree. The real build and Vulkan run are tested in a VM (see
# docs/routes/app.md, "Vulkan").
set -u
cd "$(dirname "$0")/../.." || exit 1
D=src/app/guest/venus
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Stand-ins for pacman and vercmp (pacman's own version order for these cases).
cat > "$T/pacman" <<'EOF'
#!/bin/bash
[[ $1 == -Q && -n ${HAVE:-} ]] && { echo "vulkan-virtio $HAVE"; exit 0; }
exit 1
EOF
cat > "$T/vercmp" <<'EOF'
#!/usr/bin/env python3
import re, sys
def key(v):
    e, _, v = v.rpartition(":")
    v, _, r = v.partition("-")
    num = lambda s: [int(x) for x in re.findall(r"\d+", s)]
    return (int(e or 0), num(v), num(r))
a, b = key(sys.argv[1]), key(sys.argv[2])
print((a > b) - (a < b))
EOF
# ldd: what the driver links ($LDD_MISSING: a library that went away).
cat > "$T/ldd" <<'EOF'
#!/bin/bash
echo "	libdrm.so.2 => /usr/lib/libdrm.so.2"
[[ -z ${LDD_MISSING:-} ]] || echo "	$LDD_MISSING => not found"
EOF
# GNU install -D (macOS's has no -D): the last argument is the target.
cat > "$T/install" <<'EOF'
#!/bin/bash
src=/dev/stdin
while (( $# > 1 )); do case $1 in -D*|-m*) ;; *) src=$1 ;; esac; shift; done
mkdir -p "$(dirname "$1")" && cat "$src" > "$1"
EOF
chmod +x "$T/pacman" "$T/vercmp" "$T/ldd" "$T/install"
: > "$T/libvulkan_virtio.so"
export OMACVM_VENUS_LIB=$T/libvulkan_virtio.so

st() {   # PROBE HAVE -> the state word
  PATH="$T:$PATH" OMACVM_VENUS_PROBE=$1 HAVE=$2 "$D/vulkan-virtio.sh" --status | cut -d' ' -f1
}
expect() {   # NAME PROBE HAVE WANT
  local got; got=$(st "$2" "$3")
  [[ $got == "$4" ]] && pass "$1: $4" || fail "$1: got '$got', want '$4'"
}
V="venus=1 blob_alignment=16384"
expect "Vulkan off in the app"           "venus=0 blob_alignment=0" "1:26.2.3-1"   no-venus
expect "4 KiB pages (no alignment)"      "venus=1 blob_alignment=4096" "1:26.2.3-1" no-pages
expect "old kernel (alignment unknown)"  "venus=1 blob_alignment=0" "1:26.2.3-1"    no-pages
expect "Arch Linux ARM's 26.2.3"         "$V" "1:26.2.3-1"   needed
expect "no Venus driver at all"          "$V" ""             needed
O=1:26.2.4.omacvm2-1
expect "ours (26.2.4 + WebGPU patch)"    "$V" "$O"           ok
expect "ours before 3.0.11 (omacvm1)"    "$V" "1:26.2.4.omacvm1-1" update
[[ $(PATH="$T:$PATH" OMACVM_VENUS_PROBE=$V HAVE=1:26.2.4.omacvm1-1 "$D/vulkan-virtio.sh" --status) == *"has newer fixes"* ]] &&
  pass "ours before 3.0.11: says the new build has fixes" || fail "ours before 3.0.11: wrong reason"
expect "ours from 3.0.0 (26.2.4-0.1)"    "$V" "1:26.2.4-0.1" update
expect "the distro's 26.2.4"             "$V" "1:26.2.4-1"   update
expect "a distro rebuild of 26.2.4"      "$V" "1:26.2.4-3"   update
expect "a newer Mesa"                    "$V" "1:26.3.1-2"   ok
[[ $(PATH="$T:$PATH" OMACVM_VENUS_PROBE=$V HAVE=1:26.3.1-2 "$D/vulkan-virtio.sh" --status) == *"no shared semaphores for WebGPU"* ]] &&
  pass "a newer Mesa: says WebGPU waits for our build" || fail "a newer Mesa: no word on WebGPU"
[[ $(PATH="$T:$PATH" OMACVM_VENUS_PROBE=$V HAVE=$O "$D/vulkan-virtio.sh" --status) != *WebGPU* ]] &&
  pass "ours: nothing about WebGPU missing" || fail "ours: says WebGPU is missing"
got=$(PATH="$T:$PATH" LDD_MISSING=libdisplay-info.so.2 OMACVM_VENUS_PROBE=$V HAVE=$O "$D/vulkan-virtio.sh" --status | cut -d' ' -f1)
[[ $got == needed ]] && pass "ours with a library gone: needed (rebuilt)" || fail "ours with a library gone: got '$got'"
got=$(PATH="$T:$PATH" LDD_MISSING=libdisplay-info.so.2 OMACVM_VENUS_PROBE=$V HAVE=1:26.3.1-2 "$D/vulkan-virtio.sh" --status | cut -d' ' -f1)
[[ $got == ok ]] && pass "the distro's newer one with a library gone: left to pacman" || fail "distro's newer one, library gone: got '$got'"

# Nothing to do -> silent, exit 0, also as a normal user (apply runs it on every app VM).
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "Vulkan off: silent" || fail "Vulkan off: rc $rc, said '$out'"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=$O "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && $out == "Vulkan (Venus): vulkan-virtio $O sizes GPU memory to 16384-byte pages" ]] &&
  pass "already fixed: one line" || fail "already fixed: rc $rc, said '$out'"
# The 3.0.0 build or the distro's 26.2.4: rebuilt with the patch (root only), not with OmacVM's Mesa.
: > "$T/icd.json"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=1:26.2.4-1 OMACVM_MESA_ICD=$T/icd.json "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "update with OmacVM's Mesa: silent" || fail "update with OmacVM's Mesa: rc $rc, said '$out'"
rm -f "$T/icd.json"
if (( EUID != 0 )); then
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=1:26.2.4-0.1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "update: builds (root only)" || fail "update did not go to the build: rc $rc, said '$out'"
fi

# --ready (the Mac's Automatic waits for it) and --want (omacvm apply, when the
# VM's Graphics gives it Vulkan: built also before the VM has the Venus device).
rd() { PATH="$T:$PATH" HAVE=$1 OMACVM_MESA_ICD=$T/${2:-none}.json "$D/vulkan-virtio.sh" --ready; echo $?; }
[[ $(rd 1:26.2.3-1) == 1 ]] && pass "--ready: 26.2.3 is not" || fail "--ready said yes to 26.2.3"
[[ $(rd "") == 1 ]] && pass "--ready: no driver is not" || fail "--ready said yes without a driver"
[[ $(rd 1:26.2.4-0.1) == 0 ]] && pass "--ready: ours" || fail "--ready said no to 26.2.4-0.1"
[[ $(rd 1:26.3.0-1) == 0 ]] && pass "--ready: a newer distro Mesa" || fail "--ready said no to 26.3.0"
: > "$T/icd.json"
[[ $(rd 1:26.2.3-1 icd) == 0 ]] && pass "--ready: OmacVM's Mesa (vulkan feature)" || fail "--ready said no with OmacVM's Mesa"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=$O OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "--want, driver there, no Venus yet: silent" || fail "--want with the driver: rc $rc, said '$out'"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.3.1-2 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "--want, a newer distro Mesa: silent" || fail "--want over a newer Mesa: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.4-0.1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "--want, 3.0.0's build: rebuilt with the patch (root only)" ||
    fail "--want did not rebuild 26.2.4-0.1: rc $rc, said '$out'"
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "--want, 26.2.3, no Venus yet: builds (root only)" ||
    fail "--want did not go to the build: rc $rc, said '$out'"
fi
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" --nonsense 2>&1); rc=$?
[[ $rc == 2 ]] && pass "unknown option: usage" || fail "unknown option: rc $rc"

# Never a partial upgrade: when installing the build tools would update an
# installed package (package lists newer than the system), the build stops
# before pacman installs anything. Root-only part run as a user on a copy.
P=$T/partial; mkdir -p "$P/venus"; cp -R "$D/." "$P/venus/"
sed -e 's/^(( EUID == 0 )) ||.*$/:/' -e "s#^LOG=.*#LOG=$P/build.log#" "$D/vulkan-virtio.sh" > "$P/venus/vulkan-virtio.sh"
cat > "$P/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
case "$1 $2" in
  "-Q vulkan-virtio") echo "vulkan-virtio 1:26.2.4-0.1"; exit 0 ;;
  "-Q spirv-tools") echo "spirv-tools 1"; exit 0 ;;   # installed: the update would be partial
  "-Q "*) exit 1 ;;
  "-T "*) echo glslang; exit 0 ;;
  "-S --print") printf 'glslang 1\n%s 2\n' $PULLS; exit 0 ;;
esac
exit 0
EOF
chmod +x "$P/pacman"; cp "$T/vercmp" "$T/ldd" "$P/"
CALLS=$P/calls PULLS=spirv-tools PATH="$P:$PATH" OMACVM_VENUS_PROBE="$V" OMACVM_MESA_ICD=$T/none.json \
  OMACVM_PKG_ADD="$PWD/src/guest/pkg-add" OMACVM_PKG_LOG=$P/pkg.log \
  bash "$P/venus/vulkan-virtio.sh" > "$P/out" 2>&1; rc=$?
[[ $rc == 4 ]] && grep -q 'spirv-tools 1 -> 2' "$P/out" && ! grep -qE 'pacman -S (--needed )?--noconfirm' "$P/calls" &&
  ! grep -q 'pacman -Rns' "$P/calls" && pass "build tools that would update installed packages: stops (exit 4: a full update first), installs nothing" ||
  fail "partial upgrade not refused: rc $rc, said '$(cat "$P/out")'"

# The package: Mesa 26.2.4 (blob alignment) + the semaphore patch; it stays over
# the distro's builds of the same Mesa, a newer Mesa replaces it.
eval "$(bash -c "source $D/PKGBUILD"' && declare -p pkgname epoch pkgver pkgrel _mesaver source sha256sums')"
fixed=$(sed -n 's/^FIXED=\([^ ]*\).*/\1/p' "$D/vulkan-virtio.sh")
[[ $pkgname == vulkan-virtio && "$epoch:$_mesaver" == "$fixed" && $pkgver == "$_mesaver".omacvm* ]] &&
  pass "PKGBUILD is $epoch:$pkgver (Mesa ${fixed#*:})" || fail "PKGBUILD $pkgname $epoch:$pkgver vs FIXED $fixed"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:$_mesaver-9") == 1 ]] && pass "ours stays over the distro's $_mesaver-x" ||
  fail "the distro's $_mesaver-9 would replace ours"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:26.3.0-1") == -1 ]] && pass "a newer Mesa replaces ours" ||
  fail "ours would hold back a newer Mesa"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
[[ ${#source[@]} == 3 && ${source[1]} == mesa-venus-opaque-fd-semaphores.patch &&
   ${source[2]} == mesa-venus-tls-after-unload.patch &&
   ${sha256sums[0]} =~ ^[0-9a-f]{64}$ && ${sha256sums[1]} == "$(sum "$D/patches/${source[1]}")" &&
   ${sha256sums[2]} == "$(sum "$D/patches/${source[2]}")" ]] &&
  pass "sources pinned by sha256 (the patch matches patches/)" || fail "sources not pinned, or the patch changed without its sha256"
grep -q 'install -m644 PKGBUILD patches/mesa-venus-opaque-fd-semaphores.patch patches/mesa-venus-tls-after-unload.patch "$B/"' "$D/vulkan-virtio.sh" &&
  grep -q 'patch .*< mesa-venus-tls-after-unload.patch' "$D/PKGBUILD" &&
  pass "the build gets both patches" || fail "vulkan-virtio.sh/PKGBUILD do not hand both patches to makepkg"

# Wired in: apply's app step runs it, check reads it.
grep -q '^venus/vulkan-virtio.sh $want ||' src/app/guest/install.sh && pass "app install runs it" || fail "app install does not run it"
grep -q 'OMACVM_GRAPHICS=//p' src/app/guest/install.sh && pass "app install builds ahead for Graphics Vulkan" || fail "app install ignores OMACVM_GRAPHICS"
grep -q 'ExecStart=/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh$' "$D/omacvm-venus-driver.service" &&
  grep -q 'omacvm-venus-driver.service' "$D/timer.sh" && grep -q '^venus/timer.sh' src/app/guest/install.sh &&
  pass "boot unit runs it" || fail "no boot unit"
# Never in the boot's critical chain: a timer after the desktop, no
# network-online.target and no [Install] on the service (a build at boot made
# multi-user.target, and with it the desktop, wait for it).
svc=$D/omacvm-venus-driver.service tmr=$D/omacvm-venus-driver.timer
if ! grep -v '^#' "$svc" | grep -q 'network-online' && ! grep -q '^\[Install\]' "$svc" && grep -q '^OnBootSec=' "$tmr" &&
   grep -q '^WantedBy=timers.target' "$tmr" && grep -q 'systemctl enable omacvm-venus-driver.timer' "$D/timer.sh" &&
   grep -q 'rm -f /etc/systemd/system/multi-user.target.wants/omacvm-venus-driver.service' "$D/timer.sh"; then
  pass "driver unit runs from a timer after boot, without network-online"
else
  fail "driver unit can delay the boot (network-online, [Install] on the service, or no timer)"
fi
grep -q 'app/guest/venus/vulkan-virtio.sh --status' src/guest/check.sh && pass "check has the Vulkan (Venus) row" || fail "no check row"

# WebGPU and GPU compute on that Vulkan (feature gpu-compute, venus/compute.sh): its own
# install step (after the vulkan feature's), and omacvm graphics runs it on a running VM.
grep -q 'want gpu-compute && \[\[ $TYPE == app \]\]' src/guest/install.sh &&
  grep -q 'app/guest/venus/compute.sh" "${F\[gpu-compute\]}"' src/guest/install.sh &&
  [[ $(grep -n 'want gpu-compute' src/guest/install.sh | cut -d: -f1) -gt $(grep -n 'want vulkan &&' src/guest/install.sh | cut -d: -f1) ]] &&
  pass "install: the gpu-compute step, after the vulkan step" || fail "install: no gpu-compute step after the vulkan step"
! grep -q 'venus/opencl.sh\|venus/webgpu.sh' src/app/guest/install.sh && pass "app install leaves OpenCL and WebGPU to gpu-compute" ||
  fail "app install still sets up OpenCL/WebGPU itself"
grep -q 'compute.sh' src/cmd/graphics.sh && pass "omacvm graphics runs compute.sh" || fail "omacvm graphics skips compute.sh"
grep -q '90-omacvm-opencl.conf' src/guest/check.sh && grep -q 'FEATURE=gpu-compute' src/guest/check.sh &&
  pass "check has the OpenCL row, under gpu-compute" || fail "no OpenCL check row under gpu-compute"
C=$T/compute; mkdir -p "$C"
for f in compute.sh; do cp "$D/$f" "$C/"; done
printf '#!/bin/bash\necho "opencl $*" >> "%s/calls"\n' "$C" > "$C/opencl.sh"
printf '#!/bin/bash\necho "webgpu $* gc=$OMACVM_GPU_COMPUTE" >> "%s/calls"\n' "$C" > "$C/webgpu.sh"
chmod +x "$C"/*.sh
cr() { rm -f "$C/calls"; printf '%s\n' "$@" > "$C/env"; OMACVM_ENV=$C/env "$C/compute.sh" ${ARG:-} >/dev/null 2>&1; cat "$C/calls" 2>/dev/null | tr '\n' ';'; }
[[ $(cr OMACVM_GRAPHICS=vulkan OMACVM_FEATURE_gpu_compute=on) == "opencl ;webgpu  gc=on;" ]] && pass "compute.sh: on with Vulkan: OpenCL and WebGPU" || fail "compute.sh on: $(cr OMACVM_GRAPHICS=vulkan OMACVM_FEATURE_gpu_compute=on)"
[[ $(cr OMACVM_GRAPHICS=vulkan) == "opencl ;webgpu  gc=on;" ]] && pass "compute.sh: no record yet (a VM from before 3.1.20): on" || fail "compute.sh without a record"
[[ $(cr OMACVM_GRAPHICS=vulkan OMACVM_FEATURE_gpu_compute=off) == "opencl --off;webgpu --off gc=off;" ]] && pass "compute.sh: off: both go" || fail "compute.sh off: $(cr OMACVM_GRAPHICS=vulkan OMACVM_FEATURE_gpu_compute=off)"
[[ $(cr OMACVM_GRAPHICS=opengl OMACVM_FEATURE_gpu_compute=on) == "opencl --off;webgpu --off gc=on;" ]] && pass "compute.sh: Graphics OpenGL: both go" || fail "compute.sh with OpenGL"
[[ $(ARG=off cr OMACVM_GRAPHICS=vulkan OMACVM_FEATURE_gpu_compute=on) == "opencl --off;webgpu --off gc=off;" ]] && pass "compute.sh off: the argument wins" || fail "compute.sh off by argument"
ARG=maybe cr OMACVM_GRAPHICS=vulkan >/dev/null; OMACVM_ENV=$C/env "$C/compute.sh" maybe >/dev/null 2>&1; [[ $? == 2 ]] && pass "compute.sh: unknown value: usage" || fail "compute.sh: unknown value accepted"

O=$T/opencl.conf; OF=$T/opencl-off
ocl() { OMACVM_OPENCL_ENV=$O OMACVM_OPENCL_OFF=$OF OMACVM_MESA_CLICD=${ICD:-$T/none.icd} "$D/opencl.sh" "$@"; }
ocl --nonsense >/dev/null 2>&1
[[ $? == 2 ]] && pass "opencl.sh: unknown option: usage" || fail "opencl.sh: unknown option accepted"
echo RUSTICL_ENABLE=zink > "$O"; echo why > "$OF"
ocl --off && [[ ! -e $O && ! -e $OF ]] && pass "opencl.sh --off removes the switch (and the reason)" || fail "opencl.sh --off kept the switch"
echo RUSTICL_ENABLE=zink > "$O"; : > "$T/ours.icd"
out=$(ICD=$T/ours.icd ocl 2>&1); rc=$?
[[ $rc == 0 && ! -e $O && $out == *"feature vulkan"* ]] && pass "opencl.sh: OmacVM's Mesa has its own rusticl" ||
  fail "opencl.sh with OmacVM's Mesa: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(ocl 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* && ! -e $O ]] && pass "opencl.sh installs as root only" ||
    fail "opencl.sh as a user: rc $rc, said '$out'"
fi
grep -q '^ZINK_DEBUG=quiet' <(sed -n "s/^printf '\(.*\)' > \"\$ENVF\"$/\1/p" "$D/opencl.sh" | sed 's/\\n/\n/g') &&
  pass "opencl.sh: the switch quiets Zink's warning (ZINK_DEBUG=quiet)" || fail "opencl.sh: no ZINK_DEBUG=quiet"
# The Zink device check at run time (opencl.sh --check after each boot): no device -> the switch goes, the reason stays.
printf '#!/bin/bash\nexit %s\n' 0 > "$T/venus-on"; chmod +x "$T/venus-on"
printf '#!/bin/bash\necho "MESA: error: Zink requires the nullDescriptor feature of KHR/EXT robustness2."; echo "Platform #0: rusticl"\n' > "$T/clinfo-none"
printf '#!/bin/bash\necho "Platform #0: rusticl"; echo " \`-- Device #0: zink Vulkan 1.4(Virtio-GPU Venus (Apple M4) (MESA_KOSMICKRISP))"\n' > "$T/clinfo-zink"
chmod +x "$T"/clinfo-*
chk() { echo RUSTICL_ENABLE=zink > "$O"; rm -f "$OF"; OMACVM_VENUS_ON=$T/venus-on OMACVM_CLINFO=$T/clinfo-$1 ocl --check; }
out=$(chk none); [[ ! -e $O && $(cat "$OF" 2>/dev/null) == *"no GPU device"*"nullDescriptor"* && $out == *"OpenCL: off"* ]] &&
  pass "opencl.sh --check: no Zink device: off, with the reason" || fail "opencl.sh --check without a device: '$out', $(cat "$OF" 2>/dev/null)"
chk zink >/dev/null; [[ -e $O && ! -e $OF ]] && pass "opencl.sh --check: a Zink device: stays on" || fail "opencl.sh --check removed a working switch"
printf '#!/bin/bash\nexit 1\n' > "$T/venus-on"
chk none >/dev/null; [[ -e $O && ! -e $OF ]] && pass "opencl.sh --check: no Venus this start: not judged" || fail "opencl.sh --check judged without Venus"
rm -f "$O"; OMACVM_VENUS_ON=$T/venus-on OMACVM_CLINFO=$T/clinfo-none ocl --check; [[ ! -e $O && ! -e $OF ]] &&
  pass "opencl.sh --check: switch off: nothing to do" || fail "opencl.sh --check with the switch off"
grep -q 'ExecStartPost=-/usr/local/share/omacvm/app/guest/venus/opencl.sh --check' "$D/omacvm-venus-driver.service" &&
  pass "the boot check runs opencl.sh --check" || fail "no OpenCL check after boot"
# F1: with the vulkan feature's Mesa the session's OpenCL loader reads only OmacVM's ICD.
grep -q '^OCL_ICD_VENDORS=$CLONLY$' "$D/install.sh" && grep -q 'cp "$CLICD" "$CLONLY/"' "$D/install.sh" &&
  grep -q 'rm -rf "$PREFIX" "$ICD" "$CLICD" "$CLONLY"' "$D/install.sh" && pass "vulkan feature: OmacVM's ICD alone (and gone on --remove)" ||
  fail "vulkan feature: the distro's rusticl still loads beside OmacVM's"

# WebGPU (venus/webgpu.sh): the launcher and Firefox's switch; --off keeps them while gpu-compute
# gives them (Graphics Vulkan) or the vulkan feature's Mesa is there.
grep -q '"WebGPU in Chromium"' src/guest/check.sh && grep -qF 'pacman -Q vulkan-virtio 2>/dev/null) == *omacvm*' src/guest/check.sh &&
  pass "check has the WebGPU row for Graphics Vulkan" || fail "no WebGPU check row for Graphics Vulkan"
grep -q './webgpu.sh --off' "$D/install.sh" && ! grep -q 'FFPREF' "$D/install.sh" && pass "vulkan feature off leaves the launcher and Firefox's switch to webgpu.sh" ||
  fail "venus/install.sh --remove deletes the launcher or Firefox's switch itself"
W=$T/root; mkdir -p "$W/etc/omacvm"
wg() { PATH="$T:$PATH" OMACVM_WEBGPU_ROOT=$W OMACVM_CHROMIUM=${CHR:-/nonexistent} "$D/webgpu.sh" "$@" >/dev/null 2>&1; }
has() { [[ -f $W/usr/local/bin/omacvm-chromium-webgpu && -L $W/usr/local/bin/omacvm-chrome-webgpu && -f $W/usr/lib/firefox/defaults/pref/omacvm-webgpu.js ]]; }
CHR=$T/ldd wg && has && [[ -f $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh: launcher, Chrome link, menu entry, Firefox's switch" || fail "webgpu.sh did not install the launcher or Firefox's switch"
echo OMACVM_GRAPHICS=vulkan > "$W/etc/omacvm/env"
wg --off; has && pass "webgpu.sh --off keeps them with Graphics Vulkan (gpu-compute on by default)" || fail "webgpu.sh --off removed them with Graphics Vulkan"
OMACVM_GPU_COMPUTE=off wg --off; ! has && [[ ! -e $W/usr/lib/firefox/defaults/pref/omacvm-webgpu.js ]] &&
  pass "webgpu.sh --off removes them with gpu-compute off" || fail "webgpu.sh --off kept them with gpu-compute off"
CHR=$T/ldd wg; printf 'OMACVM_GRAPHICS=vulkan\nOMACVM_FEATURE_gpu_compute=off\n' > "$W/etc/omacvm/env"
wg --off; ! has && pass "webgpu.sh --off: gpu-compute off in the record" || fail "webgpu.sh --off ignored the record's gpu-compute=off"
CHR=$T/ldd wg; echo OMACVM_GRAPHICS=opengl > "$W/etc/omacvm/env"; mkdir -p "$W/etc/vulkan/icd.d"; : > "$W/etc/vulkan/icd.d/omacvm_venus_icd.json"
OMACVM_GPU_COMPUTE=off wg --off; has && pass "webgpu.sh --off keeps them with the vulkan feature's Mesa" || fail "webgpu.sh --off removed the vulkan feature's launcher"
rm "$W/etc/vulkan/icd.d/omacvm_venus_icd.json"
wg --off; ! has && [[ ! -e $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh --off removes them with OpenGL" || fail "webgpu.sh --off left the launcher with OpenGL"
wg --nonsense; [[ $? == 2 ]] && pass "webgpu.sh: unknown option: usage" || fail "webgpu.sh: unknown option accepted"
wg; has && [[ ! -e $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh without Chromium: launcher, no menu entry" || fail "webgpu.sh without Chromium"

# Vulkan windows: Mesa's normal WSI when the app says it shows them (omacvm.vkwindows=1),
# else the software WSI (an older app ended Hyprland's GPU context on the import).
G=src/app/guest/omacvm-vulkan-present
d=$(mktemp -d)
sed "s#/run/omacvm/host.env#$d/host.env#" "$G" > "$d/gen"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "no host.env: software WSI" || fail "no host.env: not software WSI"
echo OMACVM_VKWINDOWS=1 > "$d/host.env"
[[ -z $(sh "$d/gen") ]] && pass "app shows Vulkan windows: normal WSI" || fail "app shows Vulkan windows: still software WSI"
printf 'OMACVM_SCREEN=2056x1329\nOMACVM_VKWINDOWS=0\n' > "$d/host.env"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "flag 0: software WSI" || fail "flag 0: not software WSI"
rm -rf "$d"
grep -q 'user-environment-generators/90-omacvm-vulkan-present' src/app/guest/install.sh &&
  grep -q 'rm -f /etc/environment.d/90-omacvm-vulkan.conf' src/app/guest/install.sh && pass "installed as a session generator" ||
  fail "generator not installed (or the old fixed file kept)"
grep -q 'value=omacvm.vkwindows=1' app/app/Sources/OmacVM/Runner.swift && pass "the app sends omacvm.vkwindows" ||
  fail "the app does not send omacvm.vkwindows"
grep -q '^Before=systemd-user-sessions.service' src/app/guest/omacvm-app-host.service && pass "host.env is written before sessions" ||
  fail "host.env may come after the session starts"
grep -q 'virgl-set-type-without-egl.patch' app/runtime/build-qemu-gpu-runtime.sh && pass "the runtime has the import patch" ||
  fail "the runtime lacks virgl-set-type-without-egl.patch"

(( fails == 0 )) && echo "venus-driver: all ok" || { echo "venus-driver: $fails failed"; exit 1; }
