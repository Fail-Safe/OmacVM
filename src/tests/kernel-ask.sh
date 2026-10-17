#!/bin/bash
# A newer Arch Linux ARM kernel is built only when the user says so: the
# memory-optimized kernel's build (10 minutes to over an hour) used to start
# by itself in every update after an ALARM release (weekly; 2026-10-17 on a
# MacBook Air, in Update VM). The VM keeps its kernel unless told to build;
# a VM without one still builds it. ALARM's version and the time estimate as
# apply and Update VM read them. Stand-ins for curl, pacman and the build.
#   src/tests/kernel-ask.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# ---------- ALARM's version and the estimate ----------
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'CURL'
#!/bin/bash
# Stand-in curl: ALARM's PKGBUILD as FAKE_PKGBUILD says, or no network.
[[ ${FAKE_PKGBUILD:-} == offline ]] && exit 6
printf '%b' "${FAKE_PKGBUILD:-pkgbase=linux-aarch64\npkgver=7.2.11\npkgrel=1\n}"
CURL
chmod +x "$T/bin/curl"
latest() { env PATH="$T/bin:$PATH" FAKE_PKGBUILD="$1" bash -c 'source "$0"; alarm_kernel_latest || echo "status $?"' "$R/src/kernel/alarm.sh"; }
expect "ALARM's version from its PKGBUILD" "7.2.11-1" "$(latest 'pkgver=7.2.11\npkgrel=1\n')"
expect "an rc and a second pkgrel" "7.3.0rc2-2" "$(latest 'pkgver=7.3.0rc2\npkgrel=2\n')"
expect "no network: status 1, nothing" "status 1" "$(latest offline)"
expect "a page that is no PKGBUILD: status 1" "status 1" "$(latest '<html>rate limited</html>\n')"
expect "a shell word in pkgver is not taken" "status 1" "$(latest 'pkgver=7.2;reboot\npkgrel=1\n')"
est() { bash -c 'source "$0"; kernel_build_minutes "$1"' "$R/src/kernel/alarm.sh" "$1"; }
expect "16 CPUs (M4 Max: about 10 minutes)" "10 15" "$(est 16)"
expect "8 CPUs" "20 30" "$(est 8)"
expect "4 CPUs (M2 Air: over an hour)" "40 60" "$(est 4)"
expect "unknown CPUs: as 4" "40 60" "$(est '')"

# ---------- build-thp-kernel.sh: keep, current, none yet ----------
# Its folder and guest/pkg-add next to it (the build's first step, here the end).
K=$T/omacvm; mkdir -p "$K/kernel" "$K/guest"
cp "$R/src/kernel/build-thp-kernel.sh" "$R/src/kernel/alarm.sh" "$R/src/kernel/thp-pkgbuild.py" "$K/kernel/"
printf '#!/bin/bash\necho "BUILD STARTS: pkg-add $*"\nexit 1\n' > "$K/guest/pkg-add"
printf '#!/bin/bash\n[[ $1 == -Q && -n ${FAKE_HAVE:-} ]] && { echo "linux-aarch64-thp $FAKE_HAVE"; exit 0; }\nexit 1\n' > "$T/bin/pacman"
printf '#!/bin/bash\necho 8\n' > "$T/bin/nproc"
printf '#!/bin/bash\necho "grub-mkconfig $*" >> "$FAKE_LOG"\n' > "$T/bin/grub-mkconfig"
# The VM's GNU sed -i (no suffix) with the Mac's sed.
cat > "$T/bin/sed" <<'SED'
#!/bin/bash
a=(); for x in "$@"; do if [[ $x == -i ]]; then a+=(-i ''); else a+=("$x"); fi; done
exec /usr/bin/sed "${a[@]}"
SED
chmod +x "$K/guest/pkg-add" "$T/bin/pacman" "$T/bin/nproc" "$T/bin/grub-mkconfig" "$T/bin/sed"
kbuild() {   # HAVE [VAR=VALUE...]: the script's output
  local have=$1; shift
  printf 'GRUB_TIMEOUT=5\n' > "$T/grub"; : > "$T/log"
  env PATH="$T/bin:$PATH" FAKE_HAVE="$have" FAKE_LOG="$T/log" OMACVM_TEST_GRUB="$T/grub" "$@" bash "$K/kernel/build-thp-kernel.sh" me 2>&1
}
out=$(kbuild 7.2.10-1 OMACVM_KERNEL_NEW=keep)
expect "keep, a newer release: the VM keeps its kernel" "yes" "$([[ $out == *"linux-aarch64-thp 7.2.10-1 stays: Arch Linux ARM has 7.2.11-1"* ]] && echo yes || echo "$out")"
expect "... and says the time and how to build it" "yes" "$([[ $out == *"about 20-30 minutes on 8 CPUs (on the Mac: omacvm update --kernel builds it)"* ]] && echo yes)"
expect "... no build" "" "$(grep -o 'BUILD STARTS' <<<"$out")"
expect "... GRUB still boots it by default" 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"' "$(grep '^GRUB_TOP_LEVEL=' "$T/grub")"
expect "... and the script ends well" "0" "$(kbuild 7.2.10-1 OMACVM_KERNEL_NEW=keep >/dev/null; echo $?)"
out=$(kbuild 7.2.10-1 OMACVM_KERNEL_NEW=build)
expect "build, a newer release: the build starts" "yes" "$([[ $out == *"a kernel build on 8 CPUs: about 20-30 minutes"*"BUILD STARTS"* ]] && echo yes || echo "$out")"
out=$(kbuild 7.2.10-1)
expect "run by hand (no OMACVM_KERNEL_NEW): builds, as before" "yes" "$([[ $out == *"BUILD STARTS"* ]] && echo yes || echo "$out")"
out=$(kbuild "" OMACVM_KERNEL_NEW=keep)
expect "keep, but no kernel yet (the feature just went on): builds" "yes" "$([[ $out == *"BUILD STARTS"* ]] && echo yes || echo "$out")"
out=$(kbuild 7.2.11-1 OMACVM_KERNEL_NEW=build)
expect "the current release: nothing to build" "yes" "$([[ $out == *"7.2.11-1 is ALARM's current kernel: nothing to build"* && $out != *"BUILD STARTS"* ]] && echo yes || echo "$out")"
out=$(kbuild 7.2.10-1 OMACVM_KERNEL_NEW=keep OMACVM_REBUILD_KERNEL=1)
expect "OMACVM_REBUILD_KERNEL=1 builds even with keep" "yes" "$([[ $out == *"BUILD STARTS"* ]] && echo yes || echo "$out")"
out=$(kbuild 7.2.10-1 OMACVM_KERNEL_NEW=keep FAKE_PKGBUILD=offline)
expect "GitHub not reachable: keeps it, as before" "yes" "$([[ $out == *"could not reach GitHub"*"keeping linux-aarch64-thp 7.2.10-1"* ]] && echo yes || echo "$out")"

# ---------- guest/install.sh passes the choice on ----------
expect "install.sh: keep unless --kernel-new build" "KERNEL_NEW=keep" "$(grep -o 'KERNEL_NEW=keep$' "$R/src/guest/install.sh" | head -1)"
expect "install.sh: the build script gets it" "1" "$(grep -c 'OMACVM_KERNEL_NEW=$KERNEL_NEW "$R/kernel/build-thp-kernel.sh"' "$R/src/guest/install.sh")"
exit $fail
