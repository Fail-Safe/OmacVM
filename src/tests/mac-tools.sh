#!/bin/bash
# Mac answers from a checkout: prefer its Swift source, but fall back to the
# installed app when the compiler cannot run it (for example, an SDK mismatch).
# Stand-ins only: no Swift compiler, app, VM or settings touched.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-tools.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
mkdir -p "$T/bin" "$T/developer" "$T/home" "$T/Installed App.app/Contents/Resources/tools"
export HOME=$T/home
unset OMACVM_APP_RUNTIME
# clt_has really checks these, rather than assuming that swift on PATH works.
export TEST_TOOLS=$T TEST_SWIFT_STATUS=65 TEST_CLT=1
cat > "$T/bin/xcode-select" <<'SH'
#!/bin/bash
[[ $TEST_CLT == 1 ]] || exit 2
printf '%s\n' "$TEST_TOOLS/developer"
SH
cat > "$T/bin/xcrun" <<'SH'
#!/bin/bash
: > "$TEST_TOOLS/xcrun-called"
printf '%s\n' "$TEST_TOOLS/bin/swift"
SH
cat > "$T/bin/swift" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_TOOLS/swift-args"
if [[ $TEST_SWIFT_STATUS == 0 ]]; then echo 'source answer'
else echo 'partial source answer'; echo 'swift: SDK mismatch' >&2; fi
exit "$TEST_SWIFT_STATUS"
SH
cat > "$T/Installed App.app/Contents/Resources/tools/mac-notch" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_TOOLS/app-args"
echo notch
exit "${TEST_APP_STATUS:-0}"
SH
chmod +x "$T/bin/"* "$T/Installed App.app/Contents/Resources/tools/mac-notch"
export PATH=$T/bin:$PATH
source "$R/src/lib/tools.sh"
app_bundle() { printf '%s\n' "$T/Installed App.app"; }

got=$(mac_tool mac-notch 'argument with spaces' '' --flag 2>"$T/stderr"); rc=$?
expect "broken Swift: installed answer, no partial source output" notch "$got"
expect "broken Swift: installed helper succeeds" 0 "$rc"
expect "broken Swift: installed helper receives every argument" $'argument with spaces\n\n--flag' "$(cat "$T/app-args" 2>/dev/null)"
expect "broken Swift: compiler diagnostic stays on stderr" 'swift: SDK mismatch' "$(cat "$T/stderr")"
expect "Swift receives the source and every argument" "${R}/src/display/mac-notch.swift"$'\nargument with spaces\n\n--flag' "$(cat "$T/swift-args")"

# A working compiler still runs the checkout, not a possibly older installed app.
TEST_SWIFT_STATUS=0
rm -f "$T/app-args"
got=$(mac_tool mac-notch 2>"$T/stderr"); rc=$?
expect "working Swift: source answer" 'source answer' "$got"
expect "working Swift: success" 0 "$rc"
expect "working Swift: no app called" no "$(test -e "$T/app-args" && echo yes || echo no)"
expect "working Swift: no diagnostics" '' "$(cat "$T/stderr")"

# No tools installed: never run a stub, not even xcrun.
TEST_CLT=0
rm -f "$T/swift-args" "$T/xcrun-called"
got=$(mac_tool mac-notch); rc=$?
expect "no CLT: installed answer" notch "$got"
expect "no CLT: success" 0 "$rc"
expect "no CLT: no Swift stub called" no "$(test -e "$T/swift-args" && echo yes || echo no)"
expect "no CLT: no xcrun called" no "$(test -e "$T/xcrun-called" && echo yes || echo no)"

# The app's own helper wins even with a working compiler and another app.
OWN=$T/Own.app/Contents/Resources
mkdir -p "$OWN/tools" "$OWN/omacvm/src"
printf '#!/bin/bash\necho own\nexit 23\n' > "$OWN/tools/mac-notch"
chmod +x "$OWN/tools/mac-notch"
TEST_CLT=1
rm -f "$T/app-args"
got=$(OMACVM_APP_RUNTIME="$OWN/runtime" mac_tool mac-notch); rc=$?
expect "runtime copy: own helper first" own "$got"
expect "runtime copy: own helper failure is returned" 23 "$rc"
got=$(_TOOLS_SRC="$OWN/omacvm/src" mac_tool mac-notch); rc=$?
expect "bundled source: own helper first" own "$got"
expect "bundled source: own helper failure is returned" 23 "$rc"
expect "own helper: no Swift called" no "$(test -e "$T/swift-args" && echo yes || echo no)"
expect "own helper: no installed app called" no "$(test -e "$T/app-args" && echo yes || echo no)"

# A failing fallback stays a failure; no source output leaks into it.
TEST_SWIFT_STATUS=65
export TEST_APP_STATUS=19
got=$(mac_tool mac-notch 2>/dev/null); rc=$?
expect "failing installed helper: only its output" notch "$got"
expect "failing installed helper: its status" 19 "$rc"
unset TEST_APP_STATUS

# Callers using errexit must still reach the fallback after a compiler failure.
got=$(/bin/bash -ec 'source "$1"; app_bundle() { printf "%s\n" "$TEST_TOOLS/Installed App.app"; }
  mac_tool mac-notch; echo survived' _ "$R/src/lib/tools.sh" 2>/dev/null); rc=$?
expect "errexit: fallback succeeds" $'notch\nsurvived' "$got"
expect "errexit: success" 0 "$rc"

# With no usable fallback, retain failure rather than reporting a false answer.
chmod -x "$T/Installed App.app/Contents/Resources/tools/mac-notch"
got=$(mac_tool mac-notch 2>"$T/stderr"); rc=$?
expect "no executable fallback: no partial output" '' "$got"
expect "no executable fallback: Swift status" 65 "$rc"
expect "no executable fallback: diagnostic retained" 'swift: SDK mismatch' "$(cat "$T/stderr")"
TEST_CLT=0
got=$(mac_tool mac-notch); rc=$?
expect "no CLT or executable helper: no answer" '' "$got"
expect "no CLT or executable helper: failure" 1 "$rc"
TEST_CLT=1
rm -f "$T/swift-args"
got=$(mac_tool mac-unknown); rc=$?
expect "unknown tool: no answer" '' "$got"
expect "unknown tool: failure" 1 "$rc"
expect "unknown tool: no Swift called" no "$(test -e "$T/swift-args" && echo yes || echo no)"
exit "$fail"
