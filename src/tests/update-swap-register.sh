#!/bin/bash
# OmacVM.app's update swap (app/scripts/update-swap.sh) does not wait for a
# LaunchServices that hangs: the new app starts after at most 10 s of it.
# Fake apps (shell scripts) with a test bundle id in a temporary folder, a
# lsregister that sleeps; nothing of an installed OmacVM is touched.
#   src/tests/update-swap-register.sh      exit 0 when all pass
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SWAP=$HERE/app/scripts/update-swap.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-swap-XXXXXX")
pass=0 fail=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
cleanup() { pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

ID=org.omacvm.test.swap-register
HOME_DIR=$T/home
mkdir -p "$HOME_DIR"
# A fake app: started with --update-check TOKEN it answers "ok" as the real
# one does once its QEMU starts, then quits.
fake() { # DIR VERSION
  local a=$1/Fake.app
  mkdir -p "$a/Contents/MacOS"
  cat > "$a/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string><key>CFBundleExecutable</key><string>fake</string>
  <key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$2</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
  cat > "$a/Contents/MacOS/fake" <<EOF
#!/bin/bash
while (( \$# )); do [[ \$1 == --update-check ]] && echo ok > "$HOME_DIR/launch-\$2"; shift; done
exit 0
EOF
  chmod +x "$a/Contents/MacOS/fake"
}
fake "$T/apps" 1.0
fake "$T/new" 2.0
printf '#!/bin/bash\nsleep 120\n' > "$T/lsregister"; chmod +x "$T/lsregister"
true & gone=$!; wait $gone   # the app that started the swap has quit
TOKEN=0123456789abcdef0123456789abcdef

start=$(date +%s)
OMACVM_TEST_LSREGISTER=$T/lsregister OMACVM_UPDATE_WAIT=30 \
  bash "$SWAP" install "$T/apps/Fake.app" "$T/new/Fake.app" "$HOME_DIR" "$gone" "$TOKEN" --work "$HOME_DIR" --quiet > "$T/swap.log" 2>&1
rc=$? took=$(( $(date +%s) - start ))
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$T/apps/Fake.app/Contents/Info.plist" 2>/dev/null)
[[ $rc == 0 && $v == 2.0 ]] && ok "swapped and started (rc $rc, version $v)" || bad "rc $rc, version $v: $(tr '\n' '|' < "$T/swap.log")"
(( took <= 20 )) && ok "a hanging LaunchServices held it up $took s (at most 10 s of it)" || bad "took $took s"
grep -q "LaunchServices did not answer within 10 s" "$T/swap.log" && ok "the log says LaunchServices did not answer" || bad "no log line"
[[ $(cat "$HOME_DIR/result" 2>/dev/null) == "installed 1.0 2.0" ]] && ok "result: installed 1.0 2.0" || bad "result: $(cat "$HOME_DIR/result" 2>/dev/null)"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME_DIR/previous/Fake.app/Contents/Info.plist" 2>/dev/null) == 1.0 ]] &&
  ok "1.0 kept as the previous version" || bad "no previous version"

echo "update swap with a hanging LaunchServices: $pass passed, $fail failed"
(( fail == 0 ))
