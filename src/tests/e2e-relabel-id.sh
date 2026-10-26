#!/bin/bash
# relabel.sh makes test copies only as the test identity (org.omacvm.app.test):
# a lane's own id (org.omacvm.app.test.<lane>, the release kits' r322, r323,
# r324) has no macOS permissions, and its QEMU asked "would like to control
# this Mac" at every VM start (54 dialogs in 36 hours on the test Mac mini).
# Offline: the id is refused before anything is unpacked or signed.
#   src/tests/e2e-relabel-id.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
H=$R/src/tests/e2e/relabel.sh
fail=0
W=$(mktemp -d "${TMPDIR:-/tmp}/e2e-relabel-id.XXXXXX")
trap 'rm -rf "$W"' EXIT
: > "$W/none.zip"

for id in org.omacvm.app.test.r324 org.omacvm.app.test.e2e org.omacvm.app org.omacvm.app.testx; do
  out=$(OMACVM_SIGN_ID=none "$H" "$W/none.zip" "$W/out" "$id" 2>&1); rc=$?
  if [[ $rc == 2 && $out == *"only org.omacvm.app.test"* && ! -e $W/out ]]; then
    echo "ok   $id refused, nothing made"
  else
    echo "FAIL $id: rc $rc, '$out'"; fail=1
  fi
done
# The test identity's own id (also when given) gets past the check: here to the empty zip.
for args in "" org.omacvm.app.test; do
  out=$(OMACVM_SIGN_ID=none "$H" "$W/none.zip" "$W/out" $args 2>&1); rc=$?
  if [[ $rc != 0 && $out != *"only org.omacvm.app.test"* ]]; then
    echo "ok   ${args:-no id}: the test identity, past the check"
  else
    echo "FAIL ${args:-no id}: rc $rc, '$out'"; fail=1
  fi
  rm -rf "$W/out"
done
exit $fail
