# Arch Linux ARM's linux-aarch64, which the memory-optimized kernel follows.
# Sourced by build-thp-kernel.sh in the VM, and on the Mac by omacvm apply and
# OmacVM.app's Update VM, which ask before a newer one is built.
ALARM_KERNEL=https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64

# alarm_kernel_latest: its current release (pkgver-pkgrel, as pacman -Q says
# it); status 1 and nothing when GitHub cannot be reached.
alarm_kernel_latest() {
  local v
  v=$(curl -fsSL --max-time 20 "$ALARM_KERNEL/PKGBUILD" | sed -n 's/^pkgver=//p; s/^pkgrel=//p' | paste -sd- -) || return 1
  [[ $v =~ ^[0-9][0-9A-Za-z.+_]*-[0-9][0-9.]*$ ]] || return 1
  echo "$v"
}

# kernel_build_minutes CPUS: "LOW HIGH", about how long the build takes on that
# many CPUs (10 minutes with 16 on an M4 Max, over an hour with 4 on an M2).
kernel_build_minutes() {
  local c=${1:-4}
  [[ $c =~ ^[1-9][0-9]*$ ]] || c=4
  echo "$(( (160 + c - 1) / c )) $(( (240 + c - 1) / c ))"
}
