#!/bin/bash
# OmacVM.app's virtio-gpu driver, offline. omacvm-virtio-gpu-load loads it
# for a start that asks for an option it has (SMBIOS omacvm.deepcolor=1, an
# older app's omacvm.hdr=1, omacvm.pointerplane=2, omacvm.vsynclock=1) or for
# its damage fix (omacvm.damage=1, "Draw only what changed"), after its
# dependencies; else the stock driver, and it says why. omacvm-smbios reads the
# strings as omacvm-app-host did. The modprobe rule falls back to the stock
# driver without the loader (in the initramfs only for a start that asks for none).
# The builder skips current builds and kernels without headers, drops the old
# by-hand install and builds of removed kernels, writes the rule only once a
# build is there, and builds as its own user id; a patch that does not apply
# or build is left out of the build (deep colour stays), the damage fix only
# on a kernel with the line it replaces. A made-up file system
# (OMACVM_VIRTIO_GPU_TEST_ROOT) and stand-ins for modprobe, insmod, modinfo,
# uname, depmod, chown, timeout and curl: no root, no network, no kernel.
#   src/tests/virtio-gpu-load.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/app/guest
LOAD=$G/virtio-gpu/omacvm-virtio-gpu-load
BUILD=$G/virtio-gpu/omacvm-virtio-gpu-build
T=$(mktemp -d "${TMPDIR:-/tmp}/virtio-gpu-load.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
lacks() {   # WHAT NEEDLE HAYSTACK
  case $3 in *"$2"*) printf 'FAIL %s\n  %s in it\n' "$1" "$2"; fail=1 ;; *) echo "ok   $1" ;; esac
}
has() {   # WHAT NEEDLE HAYSTACK
  case $3 in *"$2"*) echo "ok   $1" ;; *) printf 'FAIL %s\n  no %s in: %s\n' "$1" "$2" "$3"; fail=1 ;; esac
}

K=7.2.9-1-aarch64-ARCH
VG=usr/local/lib/omacvm/virtio-gpu
export CALLS=$T/calls FAKE_KERNEL=$K
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY

# ---------- stand-ins: each call is logged ----------
mkdir "$T/bin"
for tool in modprobe depmod chown; do
  printf '#!/bin/bash\necho "${0##*/} $*" >> "$CALLS"\n' > "$T/bin/$tool"
done
cat > "$T/bin/insmod" <<'EOF'
#!/bin/bash
echo "insmod $*" >> "$CALLS"
[[ -z ${FAKE_INSMOD_FAIL:-} ]] || { echo "insmod: ERROR: could not insert module $1: Invalid module format" >&2; exit 1; }
EOF
cat > "$T/bin/modinfo" <<'EOF'
#!/bin/bash
echo "modinfo $*" >> "$CALLS"
case "$1 $2" in
  "-F depends") echo "drm,virtio_dma_buf" ;;
  "-F vermagic") echo "$FAKE_KERNEL SMP preempt mod_unload aarch64" ;;
  "-F parm") for p in ${FAKE_PARMS-deep_color cursor_plane vsync_lock}; do echo "$p:an option (bool)"; done ;;
esac
EOF
printf '#!/bin/bash\necho "$FAKE_KERNEL"\n' > "$T/bin/uname"
# The build's fetch, patch and make never run here: the network is "down".
cat > "$T/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >> "$CALLS"
echo "curl: (6) Could not resolve host: git.kernel.org" >&2
exit 6
EOF
printf '#!/bin/bash\necho "curl $*" >> "$CALLS"\nexit 7\n' > "$T/bin/curl"
command -v sha256sum >/dev/null || printf '#!/bin/bash\nexec shasum -a 256 "$@"\n' > "$T/bin/sha256sum"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH

PATCH_SUM=$(cat "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch" "$G/virtio-gpu/linux-virtio-gpu-vsync-lock.patch" "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch" | sha256sum | cut -d' ' -f1)

# One SMBIOS type 11 structure (OEM strings): type, length 5, handle, count,
# then the strings. The count byte runs straight into the first string.
smbios() {   # ROOT STRING...
  mkdir -p "$1/sys/firmware/dmi/entries/11-0"
  python3 - "$1/sys/firmware/dmi/entries/11-0/raw" "${@:2}" <<'PY'
import sys
strings = [s.encode() for s in sys.argv[2:]]
data = bytes([11, 5, 0x2B, 0x00, len(strings)]) + b"".join(s + b"\0" for s in strings) + b"\0"
open(sys.argv[1], "wb").write(data)
PY
}

# A guest with the driver built for $K, the strings given.
guest() {   # STRING...
  rm -rf "$T/root" && mkdir -p "$T/root/$VG/$K"
  cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch" "$G/virtio-gpu/linux-virtio-gpu-vsync-lock.patch" "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch" "$T/root/$VG/"
  echo "not a real module" > "$T/root/$VG/$K/virtio-gpu.ko"
  echo "$PATCH_SUM $K" > "$T/root/$VG/$K/stamp"
  echo ours > "$T/root/$VG/$K/damage"
  smbios "$T/root" "$@"
  : > "$CALLS"
}

load() {   # runs the loader with one module option; its exit code
  OMACVM_VIRTIO_GPU_TEST_ROOT=$T/root "$LOAD" opt=1 2>> "$T/load.err"
}
said() { cat "$T/root/run/omacvm/virtio-gpu" 2>/dev/null; }
calls() { tr '\n' ';' < "$CALLS"; }
KO=$T/root/$VG/$K/virtio-gpu.ko
STOCK="modprobe --ignore-install virtio_gpu opt=1;"

# ---------- omacvm-smbios ----------
smbios "$T/s" omacvm.deepcolor=1 omacvm.screen=3024x1964 omacvm.notch=74 'omacvm.bad=$(id)' other.key=1 \
  omacvm.fullpanel=1.5x2x3x4x5 omacvm.vk-windows=1
expect "smbios: the first string too; only numbers and sizes; only omacvm. keys" \
  "OMACVM_DEEPCOLOR=1;OMACVM_SCREEN=3024x1964;OMACVM_NOTCH=74;OMACVM_FULLPANEL=1.5x2x3x4x5;" \
  "$(python3 -I "$G/omacvm-smbios" "$T/s/sys/firmware/dmi/entries" | tr '\n' ';')"
mkdir -p "$T/s/sys/firmware/dmi/entries/11-1"; printf '\013' > "$T/s/sys/firmware/dmi/entries/11-1/raw"
expect "smbios: a cut-off structure is left out" "4" \
  "$(python3 -I "$G/omacvm-smbios" "$T/s/sys/firmware/dmi/entries" | wc -l | tr -d ' ')"
expect "smbios: no structures, no lines" "" "$(python3 -I "$G/omacvm-smbios" "$T/none")"
has "omacvm-app-host reads the strings with omacvm-smbios" \
  "python3 -I /usr/local/lib/omacvm/omacvm-smbios > \"\$out.tmp\"" "$(cat "$G/omacvm-app-host")"
# The loader finds the helper beside its own folder, in the tree and in the VM.
has "install.sh puts omacvm-smbios where the loader looks (../omacvm-smbios)" \
  "install -Dm755 omacvm-smbios /usr/local/lib/omacvm/omacvm-smbios" "$(cat "$G/install.sh")"
has "install.sh puts the loader where the modprobe rule runs it" "VG=/$VG" "$(cat "$G/install.sh")"
has "install.sh builds it on every apply, never fatal, into a log" \
  '$VG/omacvm-virtio-gpu-build --hook > /var/log/omacvm-virtio-gpu.log 2>&1 || true' "$(cat "$G/install.sh")"
HOOK=$(cat "$G/virtio-gpu/95-omacvm-virtio-gpu.hook")
has "pacman hook: runs the installed builder" "Exec = /$VG/omacvm-virtio-gpu-build --hook" "$HOOK"
for p in linux-aarch64 linux-aarch64-headers linux-aarch64-thp linux-aarch64-thp-headers; do
  has "pacman hook: after $p" "$(printf 'Target = %s\n' "$p")" "$HOOK"
done

# ---------- omacvm-virtio-gpu-load ----------
# guest() builds with the damage fix ("ours", a 7.2 kernel); nofix: the kernel has it.
nofix() { echo kernel > "$T/root/$VG/$K/damage"; }
P1="modinfo -F parm $KO;"
DEPS="modinfo -F depends $KO;modprobe -q drm;modprobe -q virtio_dma_buf;"

guest omacvm.vkwindows=1 omacvm.screen=3024x1964
load; expect "not asked, the build has the damage fix: exit 0" 0 $?
expect "not asked, the build has the damage fix: stock (only a switch loads ours)" "stock not asked for this start" "$(said)"
expect "not asked, the damage fix: only the stock driver, with the options" "$P1$STOCK" "$(calls)"

# Draw only what changed (omacvm.damage=1): ours for its damage fix.
guest omacvm.damage=1 omacvm.screen=3024x1964
load; expect "omacvm.damage=1, the build has the damage fix: exit 0" 0 $?
expect "omacvm.damage=1, the damage fix: ours at 8 bits" "omacvm 8-bit" "$(said)"
expect "omacvm.damage=1: its dependencies, then ours with only the given options" "$P1${DEPS}insmod $KO opt=1;" "$(calls)"

guest omacvm.damage=1; nofix
load; expect "omacvm.damage=1, the kernel's own damage fix: exit 0" 0 $?
expect "omacvm.damage=1, the kernel's own fix: stock, and why" "stock not needed: the kernel keeps the damage itself" "$(said)"
expect "omacvm.damage=1, the kernel's own fix: only the stock driver, with the options" "$P1$STOCK" "$(calls)"

guest omacvm.damage=1; rm "$T/root/$VG/$K/damage"
load; expect "omacvm.damage=1, the build left the damage fix out: stock, and why" "stock built without damage_clips for $K" "$(said)"
expect "omacvm.damage=1, no damage fix: no insmod" "$P1$STOCK" "$(calls)"
guest omacvm.damage=1; echo unknown > "$T/root/$VG/$K/damage"
load; expect "omacvm.damage=1, the build could not tell (unknown): stock, and why" "stock built without damage_clips for $K" "$(said)"
guest omacvm.deepcolor=1 omacvm.damage=1; rm "$T/root/$VG/$K/damage"
load; expect "HDR + omacvm.damage=1, the build left the damage fix out: ours for HDR, and it says so" "omacvm without damage_clips" "$(said)"
guest omacvm.deepcolor=1 omacvm.damage=1
load; expect "HDR + omacvm.damage=1: ours, 10-bit" "omacvm" "$(said)"
has "HDR + omacvm.damage=1: insmod with deep_color=1 only (the damage fix is no option)" "insmod $KO opt=1 deep_color=1;" "$(calls)"
guest omacvm.damage=0
load; expect "omacvm.damage=0: stock" "stock not asked for this start" "$(said)"

guest omacvm.deepcolor=1 omacvm.vkwindows=1
load; expect "asked (the first string), built: exit 0" 0 $?
expect "asked, built: ours" "omacvm" "$(said)"
expect "asked, built: its dependencies first, then ours with the options and deep_color=1" \
  "$P1${DEPS}insmod $KO opt=1 deep_color=1;" "$(calls)"

guest omacvm.screen=3024x1964 omacvm.hdr=1
load; expect "an older app's omacvm.hdr=1: ours" "omacvm" "$(said)"
has "omacvm.hdr=1: insmod with deep_color=1" "insmod $KO opt=1 deep_color=1;" "$(calls)"

guest omacvm.pointerplane=2 omacvm.screen=3024x1964; nofix
load; expect "pointer on its own layer (omacvm.pointerplane=2): ours at 8 bits, its option said" "omacvm 8-bit cursor_plane=1" "$(said)"
has "omacvm.pointerplane=2: insmod with cursor_plane=1, then the given options, no deep_color (the stock formats)" "insmod $KO cursor_plane=1 opt=1;" "$(calls)"

guest omacvm.pointerplane=2 omacvm.hwcursor=1; nofix
load; expect "pointer plane with the Mac pointer (needs the hotspot), no damage fix to add: not ours" "stock not asked for this start" "$(said)"
expect "pointer plane + Mac pointer: only the stock driver" "$P1$STOCK" "$(calls)"
guest omacvm.pointerplane=2 omacvm.hwcursor=1
load; expect "pointer plane with the Mac pointer, the build has the damage fix, not asked: stock" "stock not asked for this start" "$(said)"
guest omacvm.pointerplane=2 omacvm.hwcursor=1 omacvm.damage=1
load; expect "pointer plane with the Mac pointer, omacvm.damage=1: ours, no cursor_plane" "omacvm 8-bit" "$(said)"
has "pointer plane + Mac pointer, omacvm.damage=1: insmod without cursor_plane" "insmod $KO opt=1;" "$(calls)"

guest omacvm.deepcolor=1 omacvm.pointerplane=2 omacvm.hwcursor=1
load; expect "10-bit, pointer plane and Mac pointer: ours without cursor_plane" "omacvm" "$(said)"

guest omacvm.deepcolor=1 omacvm.pointerplane=2
load; expect "10-bit and pointer plane: ours with cursor_plane=1" "omacvm cursor_plane=1" "$(said)"
has "10-bit and pointer plane: insmod with both" "insmod $KO cursor_plane=1 opt=1 deep_color=1;" "$(calls)"

guest omacvm.deepcolor=1
load; expect "10-bit only: no cursor_plane" "omacvm" "$(said)"
has "10-bit only: insmod with the given options and deep_color=1" "insmod $KO opt=1 deep_color=1;" "$(calls)"

guest omacvm.pointerplane=0; nofix
load; expect "pointer plane switch off (=0): stock" "stock not asked for this start" "$(said)"

# An app whose QEMU shows the pointer over its main window only (3.2.3 and
# older: omacvm.pointerplane=1): no plane, Hyprland draws the pointer on every
# display (with the plane, other displays showed none, #554).
guest omacvm.pointerplane=1 omacvm.screen=3024x1964; nofix
load; expect "an older app's omacvm.pointerplane=1: stock, and why" \
  "stock the app shows the pointer layer on its main display only (update the app)" "$(said)"
expect "omacvm.pointerplane=1: only the stock driver" "$P1$STOCK" "$(calls)"
guest omacvm.deepcolor=1 omacvm.pointerplane=1
load; expect "10-bit and an older app's pointer plane: ours without cursor_plane" "omacvm" "$(said)"
has "10-bit and omacvm.pointerplane=1: no cursor_plane" "insmod $KO opt=1 deep_color=1;" "$(calls)"
has "the app's switch sends the value the loader takes (2: QEMU shows it on every display)" \
  '"type=11,value=omacvm.pointerplane=2"' "$(cat "$R/app/app/Sources/OmacVM/Runner.swift")"

guest omacvm.vsynclock=1 omacvm.screen=3024x1964
load; expect "frames in step (omacvm.vsynclock=1): ours at 8 bits, its option said" "omacvm 8-bit vsync_lock=1" "$(said)"
has "omacvm.vsynclock=1: insmod with vsync_lock=1, then the given options, no deep_color" "insmod $KO vsync_lock=1 opt=1;" "$(calls)"

guest omacvm.deepcolor=1 omacvm.pointerplane=2 omacvm.vsynclock=1
load; expect "all three switches: ours with both options" "omacvm cursor_plane=1 vsync_lock=1" "$(said)"
has "all three: insmod with all three options" "insmod $KO cursor_plane=1 vsync_lock=1 opt=1 deep_color=1;" "$(calls)"

guest omacvm.vsynclock=0; nofix
load; expect "frames in step off (=0): stock" "stock not asked for this start" "$(said)"

# A build without the vsync lock (its patch did not fit the kernel): only the options it has.
guest omacvm.deepcolor=1 omacvm.pointerplane=2 omacvm.vsynclock=1
FAKE_PARMS="deep_color cursor_plane" load
expect "build without vsync_lock: ours, the others' options, and it says so" "omacvm cursor_plane=1 without vsync_lock" "$(said)"
has "build without vsync_lock: insmod without it" "insmod $KO cursor_plane=1 opt=1 deep_color=1;" "$(calls)"
guest omacvm.vsynclock=1; nofix
FAKE_PARMS="deep_color cursor_plane" load
expect "only frames in step asked, the build has no vsync_lock, no damage fix: stock, and why" "stock built without vsync_lock for $K" "$(said)"
expect "only frames in step asked, no vsync_lock: no insmod" "$P1$STOCK" "$(calls)"
guest omacvm.deepcolor=1 omacvm.vsynclock=1
FAKE_PARMS="deep_color" load
expect "HDR + frames in step on a build with deep colour only: HDR stays ours" "omacvm without vsync_lock" "$(said)"

guest omacvm.deepcolor=0 omacvm.hdr=0; nofix
load; expect "switch off (=0): stock" "stock not asked for this start" "$(said)"
expect "switch off: no insmod" "$P1$STOCK" "$(calls)"
guest omacvm.deepcolor=0 omacvm.hdr=0
load; expect "switch off (=0), the build has the damage fix: stock" "stock not asked for this start" "$(said)"
guest omacvm.deepcolor=0 omacvm.hdr=0 omacvm.damage=1
load; expect "HDR off (=0), omacvm.damage=1: ours at 8 bits, no deep_color" "omacvm 8-bit" "$(said)"
has "HDR off, omacvm.damage=1: insmod without deep_color" "insmod $KO opt=1;" "$(calls)"

# A build without the cursor plane (its patch did not fit the kernel): only the options it has.
guest omacvm.deepcolor=1 omacvm.pointerplane=2
FAKE_PARMS="deep_color" load
expect "build without cursor_plane: ours, HDR stays, and it says so" "omacvm without cursor_plane" "$(said)"
has "build without cursor_plane: insmod without it" "insmod $KO opt=1 deep_color=1;" "$(calls)"
guest omacvm.pointerplane=2; nofix
FAKE_PARMS="deep_color" load
expect "only the pointer layer asked, the build has no cursor_plane, no damage fix: stock, and why" "stock built without cursor_plane for $K" "$(said)"
expect "only the pointer layer asked, no cursor_plane: no insmod" "$P1$STOCK" "$(calls)"
guest omacvm.pointerplane=2
FAKE_PARMS="deep_color" load
expect "only the pointer layer asked, no cursor_plane, the build has the damage fix: stock, and why" "stock built without cursor_plane for $K" "$(said)"
guest omacvm.pointerplane=2 omacvm.damage=1
FAKE_PARMS="deep_color" load
expect "pointer layer + omacvm.damage=1, no cursor_plane: ours at 8 bits, and it says so" "omacvm 8-bit without cursor_plane" "$(said)"
guest omacvm.deepcolor=1 omacvm.pointerplane=2
FAKE_PARMS="" load
expect "modinfo lists no options: all asked, as before" "omacvm cursor_plane=1" "$(said)"
guest omacvm.pointerplane=2 omacvm.vsynclock=1
FAKE_PARMS="" load
expect "modinfo lists no options, pointer + frames in step: all asked" "omacvm 8-bit cursor_plane=1 vsync_lock=1" "$(said)"

guest omacvm.deepcolor=1
FAKE_KERNEL=7.3.0-1-aarch64-ARCH load; expect "asked, another kernel: exit 0" 0 $?
expect "asked, not built for this kernel: stock, and why" "stock not built for 7.3.0-1-aarch64-ARCH" "$(said)"
expect "asked, not built: only the stock driver" "$STOCK" "$(calls)"
guest omacvm.vkwindows=1
FAKE_KERNEL=7.3.0-1-aarch64-ARCH load
expect "not asked, not built for this kernel: stock, and why" "stock not built for 7.3.0-1-aarch64-ARCH" "$(said)"

guest omacvm.deepcolor=1
echo "0000 $K" > "$T/root/$VG/$K/stamp"
load; expect "asked, built from another patch: stock" "stock stamp out of date" "$(said)"
expect "stamp out of date: no insmod" "$STOCK" "$(calls)"
guest omacvm.vkwindows=1
echo "0000 $K" > "$T/root/$VG/$K/stamp"
load; expect "not asked, built from another patch (the damage fix before it was added): stock" "stock stamp out of date" "$(said)"
guest omacvm.deepcolor=1
rm "$T/root/$VG/$K/stamp"
load; expect "asked, no stamp: stock" "stock stamp out of date" "$(said)"

guest omacvm.deepcolor=1
FAKE_INSMOD_FAIL=1 load; expect "insmod fails: exit 0 (the stock driver loaded)" 0 $?
expect "insmod fails: stock, and insmod's message" \
  "stock insmod failed: insmod: ERROR: could not insert module $KO: Invalid module format" "$(said)"
has "insmod fails: then the stock driver" "insmod $KO opt=1 deep_color=1;$STOCK" "$(calls)"

guest omacvm.deepcolor=1
rm -rf "$T/root/sys"
load; expect "no SMBIOS strings at all, the build has the damage fix: stock" "stock not asked for this start" "$(said)"
guest omacvm.deepcolor=1; nofix
rm -rf "$T/root/sys"
load; expect "no SMBIOS strings at all, no damage fix to add: stock" "stock not asked for this start" "$(said)"

guest omacvm.deepcolor=1
OMACVM_VIRTIO_GPU_TEST_ROOT=$T/root "$LOAD" 2>> "$T/load.err"
expect "no module options: only deep_color=1" "$P1${DEPS}insmod $KO deep_color=1;" "$(calls)"
expect "the loader writes nothing to stderr" "" "$(cat "$T/load.err")"

# ---------- the modprobe rule, as modprobe runs it (sh -c, $CMDLINE_OPTS filled in) ----------
mkdir -p "$T/r"
OMACVM_VIRTIO_GPU_TEST_ROOT=$T/r "$BUILD" --remove > /dev/null   # nothing there: fine
rule_line=$(sed -n 's/^install virtio_gpu //p' "$BUILD")
expect "the rule: the loader if it is there; without it (the initramfs) nothing for a start that asks for ours, else the stock driver" \
  'if [ -x /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-load ]; then /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-load $CMDLINE_OPTS || /sbin/modprobe --ignore-install virtio_gpu $CMDLINE_OPTS; elif grep -qs -e omacvm.deepcolor=1 -e omacvm.hdr=1 -e omacvm.pointerplane=2 -e omacvm.vsynclock=1 -e omacvm.damage=1 /sys/firmware/dmi/entries/11-*/raw; then :; else /sbin/modprobe --ignore-install virtio_gpu $CMDLINE_OPTS; fi' \
  "$rule_line"
run_rule() {   # LOADER (a path) SMBIOS-ROOT: runs the rule with the loader, modprobe and SMBIOS swapped for stand-ins
  local cmd=${rule_line//\$CMDLINE_OPTS/opt=1}
  cmd=${cmd//\/usr\/local\/lib\/omacvm\/virtio-gpu\/omacvm-virtio-gpu-load/$1}
  cmd=${cmd//\/sbin\/modprobe/$T/bin/modprobe}
  cmd=${cmd//\/sys\/firmware/$2/sys/firmware}
  : > "$CALLS"
  sh -c "$cmd"
}
smbios "$T/rs" omacvm.notchskip=1 omacvm.deepcolor=1
smbios "$T/rn" omacvm.notchskip=1
smbios "$T/ro" omacvm.pointerplane=2
smbios "$T/ro1" omacvm.pointerplane=1
smbios "$T/rv" omacvm.vsynclock=1
smbios "$T/rd" omacvm.damage=1
run_rule "$T/r/missing" "$T/rn"; expect "rule: no loader (the initramfs), an 8-bit start: the stock driver (boot messages on screen)" "0 $STOCK" "$? $(calls)"
run_rule "$T/r/missing" "$T/rs"; expect "rule: no loader (the initramfs), a 10-bit start: nothing yet (the real root loads it)" "0 " "$? $(calls)"
run_rule "$T/r/missing" "$T/ro"; expect "rule: no loader (the initramfs), a pointer-plane start: nothing yet" "0 " "$? $(calls)"
run_rule "$T/r/missing" "$T/ro1"; expect "rule: no loader (the initramfs), an older app's pointer plane: the stock driver" "0 $STOCK" "$? $(calls)"
run_rule "$T/r/missing" "$T/rv"; expect "rule: no loader (the initramfs), a frames-in-step start: nothing yet" "0 " "$? $(calls)"
run_rule "$T/r/missing" "$T/rd"; expect "rule: no loader (the initramfs), a Draw only what changed start: nothing yet" "0 " "$? $(calls)"
run_rule "$T/r/missing" "$T/none"; expect "rule: no loader, no SMBIOS: the stock driver" "0 $STOCK" "$? $(calls)"
printf '#!/bin/sh\necho "loader $*" >> "$CALLS"\n' > "$T/r/ok"; chmod +x "$T/r/ok"
run_rule "$T/r/ok" "$T/rs"; expect "rule: the loader, and nothing else when it loaded a driver" "0 loader opt=1;" "$? $(calls)"
printf '#!/bin/sh\necho "loader $*" >> "$CALLS"\nexit 1\n' > "$T/r/bad"; chmod +x "$T/r/bad"
run_rule "$T/r/bad" "$T/rn"; expect "rule: a failing loader: the stock driver after all" "0 loader opt=1;$STOCK" "$? $(calls)"

# ---------- omacvm-virtio-gpu-build (only what needs no network) ----------
B=$T/b
builder() { OMACVM_VIRTIO_GPU_TEST_ROOT=$B "$BUILD" "$@" 2>&1; }
mkdir -p "$B/tmp" "$B/$VG/$K" "$B/lib/modules/$K/build" "$B/lib/modules/$K/kernel" "$B/lib/modules/$K/updates" \
  "$B/lib/modules/7.1.4-1-aarch64-ARCH/kernel" "$B/$VG/7.0.9-1-aarch64-ARCH" "$B/etc/omacvm"
cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch" "$G/virtio-gpu/linux-virtio-gpu-vsync-lock.patch" "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch" "$B/$VG/"
echo "module" > "$B/$VG/$K/virtio-gpu.ko"; echo "$PATCH_SUM $K" > "$B/$VG/$K/stamp"
echo "old" > "$B/lib/modules/$K/updates/virtio-gpu.ko"; : > "$B/etc/omacvm/virtio-gpu-deep-color"
: > "$CALLS"
out=$(builder); expect "running kernel, current build: exit 0" 0 $?
expect "current build: nothing fetched or built" "" "$(grep -E '^(curl|timeout|chown)' "$CALLS")"
has "current build: says so" "$K: up to date" "$out"
expect "the old by-hand install goes (module, marker), depmod for its kernel" "0 0 depmod -a $K;" \
  "$(ls "$B/lib/modules/$K/updates" | wc -l | tr -d ' ') $(ls "$B/etc/omacvm" | wc -l | tr -d ' ') $(calls)"
RULE=$B/etc/modprobe.d/omacvm-virtio-gpu.conf
expect "the modprobe rule is written once a build is there" "install virtio_gpu $rule_line" "$(grep -v '^#' "$RULE" 2>/dev/null)"

: > "$CALLS"
out=$(builder --kernel 7.1.4-1-aarch64-ARCH); expect "no headers: exit 0" 0 $?
expect "no headers: one line why" "omacvm-virtio-gpu: 7.1.4-1-aarch64-ARCH: no kernel headers ($B/lib/modules/7.1.4-1-aarch64-ARCH/build), skipped" "$out"
expect "no headers: nothing fetched, no depmod" "" "$(calls)"

: > "$CALLS"
out=$(builder --hook); expect "hook: exit 0" 0 $?
expect "hook: the build of a removed kernel goes, the current one stays" "$K/" "$(cd "$B/$VG" && echo */)"
has "hook: the kernel without headers is skipped" "7.1.4-1-aarch64-ARCH: no kernel headers" "$out"
expect "hook: nothing fetched" "" "$(grep -E '^(curl|timeout|chown)' "$CALLS")"

mkdir -p "$B/run/omacvm"; echo omacvm > "$B/run/omacvm/virtio-gpu"
out=$(builder --status); rc=$?
expect "status: built (exit 0)" "0 built for $K (this start: omacvm)" "$rc $out"
printf '%s\n' "cursor_plane: cursor_plane does not apply to 7.2.9" "damage_clips: damage_clips does not build on 7.2.9" > "$B/$VG/$K/without"
out=$(builder --status); rc=$?
expect "status: built, and what it left out" \
  "0 built for $K without cursor_plane: cursor_plane does not apply to 7.2.9; without damage_clips: damage_clips does not build on 7.2.9 (this start: omacvm)" "$rc $out"
rm "$B/$VG/$K/without"
out=$(FAKE_KERNEL=7.1.4-1-aarch64-ARCH builder --status); rc=$?
expect "status: no headers (exit 1)" "1 not built for 7.1.4-1-aarch64-ARCH: no kernel headers (this start: omacvm)" "$rc $out"

# A build from another patch is built again, as its own user id, with the proxy.
echo "0000 $K" > "$B/$VG/$K/stamp"; rm "$B/run/omacvm/virtio-gpu"
: > "$CALLS"
out=$(https_proxy=http://10.0.2.2:7890 builder --kernel "$K"); expect "stale build, no network: exit 1" 1 $?
has "stale build: built again, as its own user id, in a clean environment with the proxy" \
  "setpriv --reuid=64917 --regid=64917 --clear-groups --no-new-privs -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=" "$(calls)"
has "stale build: the proxy goes along" "LC_ALL=C https_proxy=http://10.0.2.2:7890 " "$(calls)"
has "stale build: kernel, its tag's version" "--unprivileged $K 7.2.9 " "$(calls)"
has "stale build: within the time cap" "timeout --kill-after=10 " "$(calls)"
has "stale build: its work folder belongs to the build's user id" "chown 64917:64917 " "$(calls)"
has "stale build: says why it failed" "$K: not built: curl: (6) Could not resolve host: git.kernel.org" "$out"
expect "stale build: the old one stays (the loader refuses it by its stamp)" "module" "$(cat "$B/$VG/$K/virtio-gpu.ko")"
out=$(builder --status)
expect "status: the failed build's reason" \
  "not built for $K: build failed: curl: (6) Could not resolve host: git.kernel.org (this start: stock, loaded without omacvm-virtio-gpu-load)" "$out"
expect "nothing left in the temp folder" "" "$(ls -A "$B/tmp")"

mkdir -p "$B/lib/modules/7.3.0-1-aarch64-ARCH/build"
: > "$CALLS"
builder --kernel 7.3.0-1-aarch64-ARCH > /dev/null
has "a .0 kernel: fetched from tag v7.3" "--unprivileged 7.3.0-1-aarch64-ARCH 7.3 " "$(calls)"
out=$(builder --kernel ../x); expect "not a kernel name: exit 1" "1 omacvm-virtio-gpu: not a kernel name: ../x" "$? $out"

out=$(builder --remove); expect "remove: exit 0" 0 $?
expect "remove: builds and rule go, the scripts' folder stays" "linux-virtio-gpu-cursor-plane.patch linux-virtio-gpu-damage-clips.patch linux-virtio-gpu-deep-color.patch linux-virtio-gpu-vsync-lock.patch -" \
  "$(ls "$B/$VG" | tr '\n' ' ')$([[ -e $RULE ]] && echo rule || echo -)"

rm -rf "$B" && mkdir -p "$B/$VG" "$B/lib/modules/$K/kernel"
cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch" "$G/virtio-gpu/linux-virtio-gpu-vsync-lock.patch" "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch" "$B/$VG/"
builder --hook > /dev/null
expect "no build anywhere: no modprobe rule" "-" "$([[ -e $RULE ]] && echo rule || echo -)"

# The unprivileged step (fetch, patch, build) with stand-ins: a patch that does not apply or
# build is left out and said; the damage fix only on a kernel without it; deep colour alone
# failing is no build.
U=$T/u; mkdir -p "$U/bin" "$U/root/$VG" "$U/lib/modules/$K/build"
cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch" "$G/virtio-gpu/linux-virtio-gpu-vsync-lock.patch" "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch" "$U/root/$VG/"
cat > "$U/bin/curl" <<'EOS'
#!/bin/bash
while (( $# )); do
  if [[ $1 == -o ]]; then
    if [[ $2 != */virtgpu_plane.c ]]; then echo "src" > "$2"
    elif [[ -z ${FAKE_HAS_FIX:-} ]]; then echo '		new_plane_state->ignore_damage_clips = true;' > "$2"
    elif [[ $FAKE_HAS_FIX == 1 ]]; then echo '		old_plane_state->fb != new_plane_state->fb && bo->dumb;' > "$2"
    else echo "src" > "$2"; fi
  fi
  shift
done
EOS
cat > "$U/bin/patch" <<'EOS'
#!/bin/bash
d="" i=""
while (( $# )); do case $1 in -d) d=$2; shift ;; -i) i=$2; shift ;; esac; shift; done
n=${i##*/linux-virtio-gpu-}; n=${n%.patch}
[[ " ${FAKE_PATCH_FAIL:-} " == *" $n "* ]] && { echo "1 out of 3 hunks FAILED -- saving rejects" >&2; exit 1; }
echo "$n" >> "$d/drivers/gpu/drm/virtio/.applied"
EOS
cat > "$U/bin/make" <<'EOS'
#!/bin/bash
m=""; for a; do [[ $a == M=* ]] && m=${a#M=}; done
for n in ${FAKE_MAKE_FAIL:-}; do grep -qx "$n" "$m/.applied" && { echo "error: implicit declaration of function" >&2; exit 2; }; done
tr '\n' ' ' < "$m/.applied" > "$m/virtio-gpu.ko"
EOS
printf '#!/bin/bash\n[[ $1 == -i ]] && exit 0\nexec /usr/bin/sed "$@"\n' > "$U/bin/sed"
printf '#!/bin/bash\necho 4\n' > "$U/bin/nproc"
chmod +x "$U/bin"/*
unpriv() {   # runs the build's unprivileged step; stdout: the module, stderr to $U/err
  rm -rf "$U/w" && mkdir "$U/w"
  PATH=$U/bin:$PATH OMACVM_VIRTIO_GPU_TEST_ROOT=$U/root "$BUILD" --unprivileged "$K" 7.2.9 "$U/w" 2> "$U/err"
}
said_b() { grep -E 'built without|damage fix:|no build:' "$U/err" | tr '\n' ';'; }
out=$(unpriv); expect "unprivileged: all fit: built with all four, deep colour first" "0 deep-color cursor-plane vsync-lock damage-clips " "$? $out"
expect "unprivileged: all fit: nothing left out, the damage fix is ours" "omacvm-virtio-gpu: damage fix: ours;" "$(said_b)"
out=$(FAKE_HAS_FIX=1 unpriv)
expect "a kernel with the damage fix (7.4): not patched again" "0 deep-color cursor-plane vsync-lock " "$? $out"
expect "a kernel with the damage fix: said, nothing left out, the word the loader reads (kernel)" "omacvm-virtio-gpu: damage fix: kernel;" "$(said_b)"
out=$(FAKE_HAS_FIX=neither unpriv)
expect "neither the old line nor Linux 7.4's fix: not patched" "0 deep-color cursor-plane vsync-lock " "$? $out"
expect "neither line: left out, and the damage fix is unknown (not taken for the kernel's own)" \
  "omacvm-virtio-gpu: built without damage_clips: 7.2.9's virtgpu_plane.c has neither the line it replaces nor Linux 7.4's fix;omacvm-virtio-gpu: damage fix: unknown;" "$(said_b)"
out=$(FAKE_PATCH_FAIL=damage-clips unpriv)
expect "damage patch does not apply: built with the other three" "0 deep-color cursor-plane vsync-lock " "$? $out"
expect "damage patch does not apply: says so" "omacvm-virtio-gpu: built without damage_clips: damage_clips does not apply to 7.2.9;" "$(said_b)"
out=$(FAKE_PATCH_FAIL=cursor-plane unpriv)
expect "cursor patch does not apply: deep colour and the damage fix (the vsync lock sits on it)" "0 deep-color damage-clips " "$? $out"
expect "cursor patch does not apply: it and the vsync lock left out" \
  "omacvm-virtio-gpu: built without cursor_plane: cursor_plane does not apply to 7.2.9;omacvm-virtio-gpu: built without vsync_lock: it needs cursor_plane, which is left out;omacvm-virtio-gpu: damage fix: ours;" "$(said_b)"
out=$(FAKE_PATCH_FAIL=vsync-lock unpriv)
expect "vsync patch does not apply: built with the other three" "0 deep-color cursor-plane damage-clips " "$? $out"
expect "vsync patch does not apply: says so" "omacvm-virtio-gpu: built without vsync_lock: vsync_lock does not apply to 7.2.9;omacvm-virtio-gpu: damage fix: ours;" "$(said_b)"
out=$(FAKE_MAKE_FAIL=vsync-lock unpriv)
expect "vsync lock does not build: only it goes out (each extra one is tried alone)" "0 deep-color cursor-plane damage-clips " "$? $out"
expect "vsync lock does not build: said, the damage fix stays" \
  "omacvm-virtio-gpu: built without vsync_lock: vsync_lock does not build on 7.2.9;omacvm-virtio-gpu: damage fix: ours;" "$(said_b)"
out=$(FAKE_MAKE_FAIL=damage-clips unpriv)
expect "damage fix does not build: built with the other three" "0 deep-color cursor-plane vsync-lock " "$? $out"
expect "damage fix does not build: says so" "omacvm-virtio-gpu: built without damage_clips: damage_clips does not build on 7.2.9;" "$(said_b)"
out=$(FAKE_MAKE_FAIL=cursor-plane unpriv)
expect "cursor plane does not build: it and the vsync lock (which sits on it) go out; deep colour and the damage fix stay" "0 deep-color damage-clips " "$? $out"
expect "cursor plane does not build: said, and why the vsync lock went too" \
  "omacvm-virtio-gpu: built without cursor_plane: cursor_plane does not build on 7.2.9;omacvm-virtio-gpu: built without vsync_lock: it needs cursor_plane, which is left out;omacvm-virtio-gpu: damage fix: ours;" "$(said_b)"
out=$(FAKE_MAKE_FAIL="vsync-lock damage-clips" unpriv)
expect "two extra ones do not build: deep colour alone" "0 deep-color " "$? $out"
expect "two extra ones do not build: each extra one said" \
  "omacvm-virtio-gpu: built without cursor_plane: left out, the build on 7.2.9 failed with two or more of the extra patches;omacvm-virtio-gpu: built without vsync_lock: left out, the build on 7.2.9 failed with two or more of the extra patches;omacvm-virtio-gpu: built without damage_clips: left out, the build on 7.2.9 failed with two or more of the extra patches;" "$(said_b)"
out=$(FAKE_PATCH_FAIL="cursor-plane damage-clips" unpriv)
expect "neither applies: deep colour alone" "0 deep-color " "$? $out"
out=$(FAKE_PATCH_FAIL=deep-color unpriv); rc=$?
expect "deep colour does not apply: no build (exit 1, no module)" "1 " "$rc $out"
expect "deep colour does not apply: the last line says why" "omacvm-virtio-gpu: no build: deep_color does not apply to 7.2.9" "$(tail -n1 "$U/err")"
out=$(FAKE_MAKE_FAIL=deep-color unpriv); rc=$?
expect "deep colour does not build: no build" "1 omacvm-virtio-gpu: no build: deep_color does not build on 7.2.9" "$rc $(tail -n1 "$U/err")"

# The 10-bit formats only with deep_color=1: a pointer-layer start offers the stock formats.
# The pointer layer: the hotspot rule off, and a cursor plane on every output.
# aquamarine takes a cursor for an output without a plane and shows nothing:
# Hyprland then draws no pointer there either (#554).
CUR=$(cat "$G/virtio-gpu/linux-virtio-gpu-cursor-plane.patch")
has "cursor plane: the option, read-only" "module_param_named(cursor_plane, virtio_gpu_cursor_plane, bool, 0444);" "$CUR"
has "cursor plane: the hotspot rule off with it" "dev->driver_features &= ~DRIVER_CURSOR_HOTSPOT;" "$CUR"
lacks "cursor plane: every output keeps its cursor plane (no rule for some outputs)" "virtio_gpu_plane_init(vgdev, DRM_PLANE_TYPE_CURSOR" "$CUR"
lacks "cursor plane: no output left without a plane" "virtgpu_display.c" "$CUR"

DEEP=$(cat "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch")
has "deep colour: the option, read-only" "module_param_named(deep_color, virtio_gpu_deep_color, bool, 0444);" "$DEEP"
has "deep colour: the primary plane's 10-bit formats only with it" "} else if (vgdev->has_virgl_3d && virtio_gpu_deep_color) {" "$DEEP"
has "deep colour: a 10-bit framebuffer only with it" "!(vgdev->has_virgl_3d && virtio_gpu_deep_color &&" "$DEEP"
DAMAGE=$(cat "$G/virtio-gpu/linux-virtio-gpu-damage-clips.patch")
has "damage fix: keeps the damage for rendered buffers, a full update for dumb ones (Linux 7.4)" \
  "old_plane_state->fb != new_plane_state->fb && bo->dumb;" "$DAMAGE"
has "damage fix: the builder knows the line the fix replaces" \
  "grep -q 'new_plane_state->ignore_damage_clips = true;'" "$(cat "$BUILD")"
has "damage fix: the builder knows Linux 7.4's own fix (the line the patch puts in)" \
  "grep -q 'new_plane_state->fb && bo->dumb;'" "$(cat "$BUILD")"

# Order and stamp: deep colour first, then the cursor plane (its hunks sit on the first one's),
# then the damage fix (src/tests/virtio-gpu-patches.sh applies them to real kernel sources).
has "build: deep colour, then the cursor plane, the vsync lock, the damage fix" \
  "$(printf '%s\n' '  local -a use=("$patch_file") left=()')" "$(cat "$BUILD")"
has "build: the others in this order" '  for p in "$cursor_file" "$vsync_file" "$damage_file"; do' "$(cat "$BUILD")"
has "build: a stale stamp when any patch changes" 'cat "$patch_file" "$cursor_file" "$vsync_file" "$damage_file" 2>/dev/null | sha256sum' "$(cat "$BUILD")"
has "loader: the same stamp" '"$root/linux-virtio-gpu-deep-color.patch" "$root/linux-virtio-gpu-cursor-plane.patch" "$root/linux-virtio-gpu-vsync-lock.patch" "$root/linux-virtio-gpu-damage-clips.patch"' "$(cat "$LOAD")"
has "install.sh installs the cursor-plane patch" 'install -Dm644 virtio-gpu/linux-virtio-gpu-cursor-plane.patch $VG/linux-virtio-gpu-cursor-plane.patch' "$(cat "$G/install.sh")"
has "install.sh installs the vsync-lock patch" 'install -Dm644 virtio-gpu/linux-virtio-gpu-vsync-lock.patch $VG/linux-virtio-gpu-vsync-lock.patch' "$(cat "$G/install.sh")"
has "install.sh installs the damage patch" 'install -Dm644 virtio-gpu/linux-virtio-gpu-damage-clips.patch $VG/linux-virtio-gpu-damage-clips.patch' "$(cat "$G/install.sh")"

exit $fail
