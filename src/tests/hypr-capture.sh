#!/bin/bash
# OmacVM.app's fix for screenshots and screen sharing of HDR apps (#579,
# src/app/guest/hypr-capture/): Hyprland 0.56.2's cm_helpers.glsl with two
# changes, put in only for that Hyprland.
#  1. 0.56.2/original names the v0.56.2 tag's commit and files (downloaded);
#     our cm_helpers.glsl differs from the tag's only inside "OmacVM" blocks;
#     every shader variant that includes it compiles as with Hyprland's own
#     (hypr-capture-shaders.py, glslangValidator; OMACVM_NEED_GLSLANG=1: fail
#     without it).
#  2. Our SDR white is omacvm-display-sync's sdr_max_luminance (203).
#  3. hypr-capture.sh in a fake root: in only beside a binary that carries the
#     tag's files and commit, out on any doubt (a changed byte, no binary, an
#     unreadable one, no python3, no fix folder), the hooks, a running Hyprland
#     reloaded only when it runs the installed binary, nobody else's file
#     touched, never an exit code but 0, every --status word.
#  4. omacvm check's "HDR captures" line (hdr_capture_line, taken from check.sh).
# Linux (GNU tools, as in the VM). Parts 1 and 3 need github.com (skip without).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
SRC=$here/../app/guest/hypr-capture
TAG=v0.56.2
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
expect() {   # WHAT CONDITION...
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hypr-capture.XXXXXX")
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT

# --- 2: one SDR white on both sides
white=$(sed -n 's/^#define OMACVM_SDR_WHITE \([0-9.]*\)$/\1/p' "$SRC/0.56.2/cm_helpers.glsl")
expect "our SDR white ($white) is display-sync's sdr_max_luminance" \
  test "$(grep -c "sdr_max_luminance = ${white%.0}'" "$here/../app/guest/omacvm-display-sync")" = 2

# --- 4: the check line
awk '/^hdr_capture_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$here/../guest/check.sh" > "$T/fn.sh"
if [[ -s $T/fn.sh ]]; then
  # shellcheck disable=SC1091
  source "$T/fn.sh"
  line() {   # what, status text, HDR, want
    local got; got=$(hdr_capture_line "$2" "$3")
    if [[ $got == "$4" ]]; then ok "check: $1"; else bad "check: $1: got '$got', want '$4'"; fi
  }
  line "in place" $'ok\tfixed' 1 $'ok\tfixed'
  line "in place, HDR off" $'ok\tfixed' 0 $'ok\tfixed'
  line "the user's own file" $'own\tyours' 1 $'skip\tyours'
  line "the package's files" $'pkg\ttheirs' 1 $'skip\ttheirs'
  line "not covered, HDR on" $'uncovered\tno fix' 1 $'warn\tno fix'
  line "not covered, HDR off" $'uncovered\tno fix' 0 $'skip\tno fix'
  line "not in place, HDR on" $'missing\tapply' 1 $'warn\tapply'
  line "someone else's file, HDR on" $'other\tanother' 1 $'warn\tanother'
  line "a VM without the fix, HDR on" "" 1 \
    $'warn\tOmacVM\'s fix for screenshots and screen sharing of HDR apps (Chrome) is not in this VM: Update VM'
  line "a VM without the fix, HDR off" "" 0 \
    $'skip\tOmacVM\'s fix for screenshots and screen sharing of HDR apps (Chrome) is not in this VM: Update VM'
else
  bad "no hdr_capture_line in check.sh"
fi
expect "check.sh shows the line" grep -q 'ok "HDR captures"' "$here/../guest/check.sh"

# --- the hooks never stop a transaction and run the installed script
for h in "$SRC"/*.hook; do
  expect "$(basename "$h"): no AbortOnFail" test "$(grep -c AbortOnFail "$h")" = 0
  expect "$(basename "$h"): on /usr/bin/Hyprland itself" grep -qx 'Target = usr/bin/Hyprland' "$h"
done
expect "the pre hook takes ours out" grep -qx 'Exec = /usr/local/lib/omacvm/hypr-capture/hypr-capture.sh --hook-pre' "$SRC/05-omacvm-hypr-capture-pre.hook"
expect "the pre hook runs before" grep -qx 'When = PreTransaction' "$SRC/05-omacvm-hypr-capture-pre.hook"
expect "the post hook puts it back" grep -qx 'Exec = /usr/local/lib/omacvm/hypr-capture/hypr-capture.sh --hook-post' "$SRC/95-omacvm-hypr-capture.hook"

# --- 1: the tag
G=$T/hypr
if ! git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" --filter=blob:none --no-checkout \
     https://github.com/hyprwm/Hyprland "$G" 2>/dev/null ||
   ! git -C "$G" sparse-checkout set --no-cone /src/render/shaders/glsl/ 2>/dev/null ||
   ! git -C "$G" checkout -q 2>/dev/null; then
  echo "skip: cannot download Hyprland $TAG (parts 1 and 3)"
  (( fail == 0 )) && echo "hypr-capture: all passed (offline parts only)"
  exit $fail
fi
GL=$G/src/render/shaders/glsl
expect "original names $TAG's commit" grep -qx "commit $(git -C "$G" rev-parse HEAD)" "$SRC/0.56.2/original"
while read -r kind sha size name first; do
  [[ $kind == file ]] || continue
  expect "original: $name as in $TAG" test "$(sha256sum < "$GL/$name" | cut -d' ' -f1) $(( $(wc -c < "$GL/$name") )) $(head -n1 "$GL/$name")" = "$sha $size $first"
done < "$SRC/0.56.2/original"
expect "original lists the file we replace and those that call it" \
  test "$(grep -c '^file ' "$SRC/0.56.2/original")" = 5
outside=$(python3 - "$GL/cm_helpers.glsl" "$SRC/0.56.2/cm_helpers.glsl" <<'PY'
import difflib, sys
a = open(sys.argv[1], encoding="utf-8").read().splitlines()
b = open(sys.argv[2], encoding="utf-8").read().splitlines()
inside, depth = set(), 0
for i, l in enumerate(b):
    if l.strip().startswith("// OmacVM begin"):
        depth += 1
    if depth:
        inside.add(i)
    if l.strip() == "// OmacVM end":
        depth -= 1
for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
    if op == "equal":
        continue
    # a change: what it adds lies in a block; what it drops sits where a block is
    if any(j not in inside for j in range(j1, j2)) or (j1 == j2 and j1 not in inside and j1 - 1 not in inside):
        print(f"{op} upstream {i1 + 1}-{i2} ours {j1 + 1}-{j2}")
print(f"blocks {sum(1 for l in b if l.strip().startswith('// OmacVM begin'))}")
PY
)
expect "our cm_helpers.glsl differs from $TAG's only in OmacVM blocks ($(tail -n1 <<<"$outside"))" \
  test "$(grep -vc '^blocks ' <<<"$outside")" = 0
[[ $(grep -vc '^blocks ' <<<"$outside") == 0 ]] || grep -v '^blocks ' <<<"$outside"
if command -v glslangValidator >/dev/null; then
  if python3 "$here/hypr-capture-shaders.py" "$GL" "$SRC/0.56.2/cm_helpers.glsl"; then ok "shader variants"
  else bad "shader variants"; fi
elif [[ ${OMACVM_NEED_GLSLANG:-} == 1 ]]; then bad "glslangValidator missing (glslang-tools)"
else echo "skip: shader variants (no glslangValidator)"; fi

# --- 3: hypr-capture.sh in a fake root
R=$T/root
L=$T/lib                                   # /usr/local/lib/omacvm/hypr-capture
OURS=$R/usr/local/share/hypr/shaders/cm_helpers.glsl
LOG=$T/hyprctl.log
mkdir -p "$L" "$R/usr/bin" "$T/bin"
cp -R "$SRC"/. "$L"/
# a stand-in Hyprland binary: what the real one carries, between other bytes
mkbin() {   # mkbin [sed expression for cm_helpers.glsl]
  { head -c 4096 /dev/urandom; echo "Hyprland, built from commit $(git -C "$G" rev-parse HEAD)"
    for f in constants.h CM.glsl tonemap.glsl surface.frag; do cat "$GL/$f"; printf '\0'; done
    if [[ -n ${1:-} ]]; then sed "$1" "$GL/cm_helpers.glsl"; else cat "$GL/cm_helpers.glsl"; fi
    head -c 4096 /dev/urandom; } > "$R/usr/bin/Hyprland"
}
cat > "$T/bin/hyprctl" <<EOF
#!/bin/bash
echo "\$HYPRLAND_INSTANCE_SIGNATURE \$XDG_RUNTIME_DIR \$*" >> "$LOG"
EOF
chmod 755 "$T/bin/hyprctl"
# running Hyprlands: the installed binary, a replaced one, another program
inst() {   # inst UID SIG PID EXE
  mkdir -p "$R/run/user/$1/hypr/$2" "$R/proc/$3"
  printf '%s\nwayland-1\n' "$3" > "$R/run/user/$1/hypr/$2/hyprland.lock"
  ln -sfn "$4" "$R/proc/$3/exe"
}
inst 1000 live_1_a 101 /usr/bin/Hyprland
inst 1000 old_2_b 102 '/usr/bin/Hyprland (deleted)'
inst 1001 other_3_c 103 /usr/bin/foot
run() { OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$L/hypr-capture.sh" "$@"; }
reloads() { if [[ -f $LOG ]]; then grep -c reloadshaders "$LOG"; else echo 0; fi; }
status() { run --status "$@" | cut -f1; }
rc() { run "$@" >/dev/null 2>&1; echo $?; }

mkbin
: > "$LOG"
expect "the tag's binary: exit 0" test "$(rc)" = 0
expect "the tag's binary: ours in place" cmp -s "$SRC/0.56.2/cm_helpers.glsl" "$OURS"
expect "ours: 0644" test "$(stat -c %a "$OURS")" = 644
expect "the state names the release and our file" \
  test "$(cat "$R/var/lib/omacvm/hypr-capture")" = "0.56.2 $(sha256sum < "$OURS" | cut -d' ' -f1)"
expect "the running Hyprland of that binary reloaded, once, in its own runtime folder" \
  test "$(cat "$LOG")" = "live_1_a /run/user/1000 reloadshaders"
expect "status: ok" test "$(status)" = ok
: > "$LOG"; run >/dev/null
expect "again: nothing changes, no reload" test "$(reloads)" = 0
expect "pre hook: exit 0" test "$(rc --hook-pre)" = 0
expect "pre hook: ours out" test ! -e "$OURS"
expect "pre hook: no reload" test "$(reloads)" = 0
expect "status after the pre hook: missing" test "$(status)" = missing
expect "post hook: exit 0" test "$(rc --hook-post)" = 0
expect "post hook: ours back" cmp -s "$SRC/0.56.2/cm_helpers.glsl" "$OURS"
expect "post hook: the live Hyprland reloaded" test "$(reloads)" = 1
mkbin 's/SDR_MAX_LUMINANCE));/SDR_MAX_LUMINANCE)); /'
: > "$LOG"
expect "one byte changed in the binary's cm_helpers.glsl: exit 0" test "$(rc --hook-post)" = 0
expect "one byte changed: ours out" test ! -e "$OURS"
expect "one byte changed: the live Hyprland reloaded (its own copy again)" test "$(reloads)" = 1
expect "one byte changed: status uncovered" test "$(status)" = uncovered
expect "one byte changed: says which file" grep -q "cm_helpers.glsl is not the one" <(run --status)
mkbin; run >/dev/null
sed -i "s/$(git -C "$G" rev-parse HEAD)/0000000000000000000000000000000000000000/" "$R/usr/bin/Hyprland"
expect "another commit: ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0
mkbin; run >/dev/null
rm "$R/usr/bin/Hyprland"
expect "no binary: exit 0, ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0
expect "no binary: status uncovered" test "$(status)" = uncovered
mkbin; run >/dev/null
chmod 000 "$R/usr/bin/Hyprland"
if [[ -r $R/usr/bin/Hyprland ]]; then echo "skip: an unreadable binary (root reads it anyway)"
else expect "an unreadable binary: exit 0, ours out" test "$(rc; [[ -e $OURS ]] && echo there)" = 0; fi
chmod 644 "$R/usr/bin/Hyprland"; run >/dev/null
# without python3: the tools the script uses, nothing else
mkdir -p "$T/nopy"
for t in bash sha256sum cut cat chmod mv mkdir mktemp rm cmp dirname basename readlink head tail getent id env \
         setsid setpriv timeout grep; do
  p=$(command -v "$t") && ln -sf "$p" "$T/nopy/$t"
done
expect "no python3: exit 0, ours out" \
  test "$(PATH=$T/nopy OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$T/nopy/bash" "$L/hypr-capture.sh" >/dev/null 2>&1; echo $?; [[ -e $OURS ]] && echo there)" = 0
run >/dev/null
mkdir -p "$T/nofix"; cp "$L/hypr-capture.sh" "$T/nofix/"
expect "no fix folder beside the script: exit 0, ours out" \
  test "$(OMACVM_HC_ROOT=$R OMACVM_HC_HYPRCTL=$T/bin/hyprctl "$T/nofix/hypr-capture.sh" >/dev/null 2>&1; echo $?; [[ -e $OURS ]] && echo there)" = 0
# a file of an older OmacVM (recorded in the state) is replaced
echo "// an older OmacVM fix" > "$OURS"
echo "0.56.2 $(sha256sum < "$OURS" | cut -d' ' -f1)" > "$R/var/lib/omacvm/hypr-capture"
run >/dev/null
expect "an older OmacVM file: replaced by this one" cmp -s "$SRC/0.56.2/cm_helpers.glsl" "$OURS"
# nobody else's file is touched
echo "// someone's own" > "$OURS"; rm -f "$R/var/lib/omacvm/hypr-capture"
run >/dev/null; run --hook-pre >/dev/null; run --remove >/dev/null
expect "someone else's file in /usr/local/share/hypr/shaders: left" grep -qx "// someone's own" "$OURS"
expect "someone else's file: status other" test "$(status)" = other
rm "$OURS"; run >/dev/null
mkdir -p "$R/usr/share/hypr/shaders"; echo "// the package's" > "$R/usr/share/hypr/shaders/cm_helpers.glsl"
run >/dev/null
expect "the package ships shader files: ours out" test ! -e "$OURS"
expect "the package ships shader files: status pkg" test "$(status)" = pkg
expect "the package's file left" grep -qx "// the package's" "$R/usr/share/hypr/shaders/cm_helpers.glsl"
rm -r "$R/usr/share/hypr"; run >/dev/null
me=$(id -un); hm=$(getent passwd "$me" | cut -d: -f6)
mkdir -p "$R$hm/.config/hypr/shaders"; echo "// mine" > "$R$hm/.config/hypr/shaders/cm_helpers.glsl"
expect "the user's own file: status own" test "$(status "$me")" = own
expect "the user's own file: ours stays in place (theirs wins in Hyprland)" test -e "$OURS"
rm -r "$R$hm/.config"
: > "$LOG"
expect "--remove: exit 0" test "$(rc --remove)" = 0
expect "--remove: ours out, the live Hyprland reloaded" test "$(reloads; [[ -e $OURS ]] && echo there)" = 1
expect "a wrong option: usage, exit 2" test "$(rc --nope)" = 2
expect "the replaced and the other program never reloaded" test "$(grep -c 'old_2_b\|other_3_c' "$LOG")" = 0

(( fail == 0 )) && echo "hypr-capture: all passed"
exit $fail
