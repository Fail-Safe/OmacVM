#!/bin/bash
# A published OmacVM-X.Y.Z.zip as the test identity, for the update path of
# cc-switches.sh: "OmacVM Test.app" (org.omacvm.app.test, helpers
# org.omacvm.test.bridge and org.omacvm.test.gestures), signed again with the
# Developer ID in OMACVM_SIGN_ID. Only the bundle ids and the signatures
# change; QEMU's runtime and everything else stay as released. QEMU is signed
# as the test app's ("org.omacvm.app.test.qemu"): the installed Gestures tells
# its own VMs by that, and would take a relabeled VM as the user's. Gestures
# picks the test port (47930) from its relabeled bundle id from 3.1.16 on; an
# older release's Gestures listens on 47830, beside the installed one, and
# cannot (the gate's VM then has no Gestures; nothing else changes).
#   src/tests/e2e/relabel.sh ZIP OUT_DIR [org.omacvm.app.test]  -> OUT_DIR/OmacVM Test.app
# Only the test identity's own id: macOS keeps its permissions for that id and
# the Developer ID team, so every copy and build of it has them. A lane's own
# id (org.omacvm.app.test.<lane>) has none: the QEMU of 3.2.4 and older asked
# "would like to control this Mac" at every VM start (54 dialogs in 36 hours
# on the test Mac mini), and Local Network asks for each new id. Local Network
# also asks again for each new build of org.omacvm.app.test, so one id does not
# stop that prompt. Another test app's settings are kept apart by the test
# identity's lock instead.
set -euo pipefail
ZIP=${1:?usage: relabel.sh ZIP OUT_DIR [ID]}; O=${2:?usage: relabel.sh ZIP OUT_DIR [ID]}; ID=${3:-org.omacvm.app.test}
[[ $ID == org.omacvm.app.test ]] || { echo "relabel.sh: $ID: only org.omacvm.app.test (a lane's own id has no macOS permissions: a dialog at every VM start)" >&2; exit 2; }
SIGN=${OMACVM_SIGN_ID:?OMACVM_SIGN_ID: a Developer ID Application identity}
PB=/usr/libexec/PlistBuddy
rm -rf "$O"; mkdir -p "$O/x"
ditto -x -k "$ZIP" "$O/x"
src=$(ls -d "$O"/x/*.app | head -1)
[[ $($PB -c "Print :CFBundleIdentifier" "$src/Contents/Info.plist") == org.omacvm.app ]] || { echo "relabel.sh: $ZIP has no org.omacvm.app" >&2; exit 1; }
A="$O/OmacVM Test.app"
mv "$src" "$A"; rm -rf "$O/x"
for h in "$A"/Contents/Helpers/*.app; do
  [[ -d $h ]] || continue
  case $($PB -c "Print :CFBundleIdentifier" "$h/Contents/Info.plist") in
    org.omacvm.bridge) new=org.omacvm.test.bridge; name="OmacVM Test Bridge" ;;
    org.omacvm.gestures) new=org.omacvm.test.gestures; name="OmacVM Test Gestures" ;;
    # Omanotch (3.0.5 on) keeps its id and signature in test builds too (build-app.sh).
    ch.gillesgoetsch.omanotch) continue ;;
    *) echo "relabel.sh: unknown helper $h" >&2; exit 1 ;;
  esac
  $PB -c "Set :CFBundleIdentifier $new" "$h/Contents/Info.plist"
  codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements -s "$SIGN" -i "$new" "$h"
  # The test identity's helpers carry their own names (src/mac/install.sh starts them by these paths).
  [[ $(basename "$h" .app) == "$name" ]] || mv "$h" "$(dirname "$h")/$name.app"
done
$PB -c "Set :CFBundleIdentifier $ID" "$A/Contents/Info.plist"
$PB -c "Set :CFBundleName OmacVM Test" "$A/Contents/Info.plist" 2>/dev/null || true
# The window's Gestures rows (escape combo, Magic Mouse swipe, Swipe out) read
# the domain build-app.sh --test-identity names; a release has none, so the
# relabeled copy would read the installed Gestures' org.omacvm.gestures.
$PB -c "Delete :OmacVMGesturesDomain" "$A/Contents/Info.plist" 2>/dev/null || true
$PB -c "Add :OmacVMGesturesDomain string org.omacvm.test.gestures" "$A/Contents/Info.plist"
for q in "$A/Contents/MacOS/OmacVM-VM" "$A/Contents/Resources/runtime/bin/OmacVM"; do
  [[ -f $q ]] || continue
  codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements -s "$SIGN" -i org.omacvm.app.test.qemu "$q"
  [[ $(codesign -dv "$q" 2>&1 | sed -n 's/^Identifier=//p') == org.omacvm.app.test.qemu ]] || { echo "relabel.sh: $q is not signed as the test app's QEMU" >&2; exit 1; }
done
codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements -s "$SIGN" -i "$ID" "$A"
codesign --verify --deep --strict "$A"
[[ $($PB -c "Print :OmacVMGesturesDomain" "$A/Contents/Info.plist") == org.omacvm.test.gestures ]] || { echo "relabel.sh: no test Gestures domain" >&2; exit 1; }
echo "$($PB -c 'Print :CFBundleShortVersionString' "$A/Contents/Info.plist") $(codesign -dv "$A" 2>&1 | grep -E '^Identifier|^TeamIdentifier' | tr '\n' ' ')gestures domain $($PB -c 'Print :OmacVMGesturesDomain' "$A/Contents/Info.plist")"
