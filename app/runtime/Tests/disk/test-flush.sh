#!/bin/bash
# Test for qemu-darwin-disk-flush-barrier.patch (no VM): the flush helper
# from the patched QEMU source, with a stand-in fcntl, in each mode.
#   test-flush.sh QEMU_SOURCE_DIR [WORK_DIR]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${1:?usage: test-flush.sh QEMU_SOURCE_DIR [WORK_DIR]}
work=${2:-$(mktemp -d "${TMPDIR:-/tmp}/omacvm-test-flush.XXXXXX")}
mkdir -p "$work"
f=$src/block/file-posix.c
awk '/^enum \{ OMACVM_FLUSH_FSYNC/ { on = 1 } on && /^#endif$/ { exit } on' "$f" > "$work/flush.inc"
[[ -s $work/flush.inc ]] || { echo "FAIL: $f has no omacvm_darwin_flush (disk flush patch)"; exit 1; }
grep -q 'ret = omacvm_darwin_flush(aiocb->aio_fildes);' "$f" || \
  { echo "FAIL: handle_aiocb_flush() does not call omacvm_darwin_flush"; exit 1; }
cc -Wall -Werror -Wno-unused-function -I"$work" "$here/test-flush.c" -o "$work/test-flush"
fail=0
run() {   # run CASE MODE WANT_STDERR
  local err
  err=$(OMACVM_DISK_FLUSH=$2 "$work/test-flush" "$1" 2>&1 >/dev/null) || fail=1
  OMACVM_DISK_FLUSH=$2 "$work/test-flush" "$1" 2>/dev/null | sed 's/^/  /' || true
  [[ $err == "$3" ]] || { echo "FAIL $1: QEMU's log said: $err"; echo "  want: $3"; fail=1; }
}
run barrier "" "OmacVM: disk flush: barrier (F_BARRIERFSYNC)"
run barrier barrier "OmacVM: disk flush: barrier (F_BARRIERFSYNC)"
run full full "OmacVM: disk flush: full (F_FULLFSYNC)"
run fsync fsync "OmacVM: disk flush: fsync (no barrier)"
run refused "" "OmacVM: disk flush: barrier (F_BARRIERFSYNC)
OmacVM: disk flush: the drive refused F_BARRIERFSYNC (Operation not supported): fsync only"
run full-refused full "OmacVM: disk flush: full (F_FULLFSYNC)
OmacVM: disk flush: the drive refused F_FULLFSYNC (Operation not supported): barrier"
run eio "" "OmacVM: disk flush: barrier (F_BARRIERFSYNC)"
(( fail == 0 )) && echo "test-flush: all ok" || { echo "test-flush: FAILED"; exit 1; }
