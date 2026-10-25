#!/bin/bash
# Offline checks for the disk flush change (no VM, no QEMU build): the patch is
# pinned, applied and tested by the runtime build, its log lines match
# omacvm check's "disk flush" line, and check's verdict for each line.
# The patch's own test (a stand-in fcntl) is app/runtime/Tests/disk/test-flush.sh,
# run by the runtime build on the patched QEMU source.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-darwin-disk-flush-barrier.patch
B=$R/app/runtime/build-qemu-gpu-runtime.sh
CHECK=$R/src/cmd/check.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

check "patch is pinned in SHA256SUMS" grep -q " qemu-darwin-disk-flush-barrier.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "runtime build applies the patch" grep -q "patches/qemu-darwin-disk-flush-barrier.patch" "$B"
check "runtime build runs its test on the patched source" grep -q 'Tests/disk/test-flush.sh" "$source_dir"' "$B"
check "the test's files are in the runtime inputs" grep -q 'Tests/disk/\*' "$R/app/scripts/build-app.sh"
check "the patch reads OMACVM_DISK_FLUSH" grep -q 'getenv("OMACVM_DISK_FLUSH")' "$P"
check "the flush handler calls the barrier helper" grep -qF '+    ret = omacvm_darwin_flush(aiocb->aio_fildes);' "$P"
check "barrier is the default" grep -qF '+static int omacvm_flush_mode = OMACVM_FLUSH_BARRIER;' "$P"
for line in "barrier (F_BARRIERFSYNC)" "full (F_FULLFSYNC)" "fsync (no barrier)" "the drive refused"; do
  check "patch logs 'disk flush: $line'" grep -qF "$line" "$P"
done
# check.sh's verdict for each line QEMU can write (its own block, run here).
verdict() {   # LOG_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); [[ -n $1 ]] && printf 'OmacVM: disk flush: %s\n' "$1" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Disk flushes (3.2.1)/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh has the disk flush block" grep -q '^# Disk flushes (3.2.1)' "$CHECK"
check "check.sh: barrier is ok" grep -q "^ok:each flush is a write barrier" <<<"$(verdict 'barrier (F_BARRIERFSYNC)')"
check "check.sh: full is ok" grep -q "^ok:each flush waits for the Mac's drive" <<<"$(verdict 'full (F_FULLFSYNC)')"
check "check.sh: fsync warns" grep -q "^warn:no write barrier" <<<"$(verdict 'fsync (no barrier)')"
check "check.sh: a refused barrier warns" grep -q "^warn:the drive the VM is on refused" \
  <<<"$(verdict 'the drive refused F_BARRIERFSYNC (Operation not supported): fsync only')"
check "check.sh: F_FULLFSYNC refused, barrier is ok" grep -q "^ok:each flush is a write barrier.*refused F_FULLFSYNC" \
  <<<"$(verdict 'the drive refused F_FULLFSYNC (Operation not supported): barrier')"
check "check.sh: an old runtime prints nothing" test -z "$(verdict '')"
echo "disk-flush: $((N - FAIL)) of $N ok"
(( FAIL == 0 ))
