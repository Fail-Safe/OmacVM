#!/bin/bash
# OmacVM.app's 10-bit virtio-gpu driver, offline. omacvm-virtio-gpu-load loads
# it only for a start that asks (SMBIOS omacvm.deepcolor=1, or an older app's
# omacvm.hdr=1) with a current build, after its dependencies; else the stock
# driver, and it says why. omacvm-smbios reads the strings as omacvm-app-host
# did. The modprobe rule falls back to the stock driver without the loader.
# The builder skips current builds and kernels without headers, drops the old
# by-hand install and builds of removed kernels, writes the rule only once a
# build is there, and builds as its own user id. A made-up file system
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

PATCH_SUM=$(sha256sum < "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" | cut -d' ' -f1)

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
  cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$T/root/$VG/"
  echo "not a real module" > "$T/root/$VG/$K/virtio-gpu.ko"
  echo "$PATCH_SUM $K" > "$T/root/$VG/$K/stamp"
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
guest omacvm.vkwindows=1 omacvm.screen=3024x1964
load; expect "not asked: exit 0" 0 $?
expect "not asked: stock, and why" "stock not asked for this start" "$(said)"
expect "not asked: only the stock driver, with the options" "$STOCK" "$(calls)"

guest omacvm.deepcolor=1 omacvm.vkwindows=1
load; expect "asked (the first string), built: exit 0" 0 $?
expect "asked, built: ours" "omacvm" "$(said)"
expect "asked, built: its dependencies first, then ours with the options" \
  "modinfo -F depends $KO;modprobe -q drm;modprobe -q virtio_dma_buf;insmod $KO opt=1;" "$(calls)"

guest omacvm.screen=3024x1964 omacvm.hdr=1
load; expect "an older app's omacvm.hdr=1: ours" "omacvm" "$(said)"
has "omacvm.hdr=1: insmod" "insmod $KO opt=1;" "$(calls)"

guest omacvm.deepcolor=0 omacvm.hdr=0
load; expect "switch off (=0): stock" "stock not asked for this start" "$(said)"
expect "switch off: no insmod" "$STOCK" "$(calls)"

guest omacvm.deepcolor=1
FAKE_KERNEL=7.3.0-1-aarch64-ARCH load; expect "asked, another kernel: exit 0" 0 $?
expect "asked, not built for this kernel: stock, and why" "stock not built for 7.3.0-1-aarch64-ARCH" "$(said)"
expect "asked, not built: only the stock driver" "$STOCK" "$(calls)"

guest omacvm.deepcolor=1
echo "0000 $K" > "$T/root/$VG/$K/stamp"
load; expect "asked, built from another patch: stock" "stock stamp out of date" "$(said)"
expect "stamp out of date: no insmod" "$STOCK" "$(calls)"
guest omacvm.deepcolor=1
rm "$T/root/$VG/$K/stamp"
load; expect "asked, no stamp: stock" "stock stamp out of date" "$(said)"

guest omacvm.deepcolor=1
FAKE_INSMOD_FAIL=1 load; expect "insmod fails: exit 0 (the stock driver loaded)" 0 $?
expect "insmod fails: stock, and insmod's message" \
  "stock insmod failed: insmod: ERROR: could not insert module $KO: Invalid module format" "$(said)"
has "insmod fails: then the stock driver" "insmod $KO opt=1;$STOCK" "$(calls)"

guest omacvm.deepcolor=1
rm -rf "$T/root/sys"
load; expect "no SMBIOS strings at all: stock" "stock not asked for this start" "$(said)"

guest omacvm.deepcolor=1
OMACVM_VIRTIO_GPU_TEST_ROOT=$T/root "$LOAD" 2>> "$T/load.err"
expect "no module options: none passed" "modinfo -F depends $KO;modprobe -q drm;modprobe -q virtio_dma_buf;insmod $KO;" "$(calls)"
expect "the loader writes nothing to stderr" "" "$(cat "$T/load.err")"

# ---------- the modprobe rule, as modprobe runs it (sh -c, $CMDLINE_OPTS filled in) ----------
mkdir -p "$T/r"
OMACVM_VIRTIO_GPU_TEST_ROOT=$T/r "$BUILD" --remove > /dev/null   # nothing there: fine
rule_line=$(sed -n 's/^install virtio_gpu //p' "$BUILD")
expect "the rule: the loader if it is there; without it (the initramfs) nothing for a 10-bit start, else the stock driver" \
  'if [ -x /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-load ]; then /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-load $CMDLINE_OPTS || /sbin/modprobe --ignore-install virtio_gpu $CMDLINE_OPTS; elif grep -qs -e omacvm.deepcolor=1 -e omacvm.hdr=1 /sys/firmware/dmi/entries/11-*/raw; then :; else /sbin/modprobe --ignore-install virtio_gpu $CMDLINE_OPTS; fi' \
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
run_rule "$T/r/missing" "$T/rn"; expect "rule: no loader (the initramfs), an 8-bit start: the stock driver" "0 $STOCK" "$? $(calls)"
run_rule "$T/r/missing" "$T/rs"; expect "rule: no loader (the initramfs), a 10-bit start: nothing yet (the real root loads it)" "0 " "$? $(calls)"
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
cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$B/$VG/"
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
expect "remove: builds and rule go, the scripts' folder stays" "linux-virtio-gpu-deep-color.patch -" \
  "$(ls "$B/$VG" | tr '\n' ' ')$([[ -e $RULE ]] && echo rule || echo -)"

rm -rf "$B" && mkdir -p "$B/$VG" "$B/lib/modules/$K/kernel"
cp "$G/virtio-gpu/linux-virtio-gpu-deep-color.patch" "$B/$VG/"
builder --hook > /dev/null
expect "no build anywhere: no modprobe rule" "-" "$([[ -e $RULE ]] && echo rule || echo -)"

exit $fail
