#!/bin/bash
# Freeing disk space (src/guest/disk-space.sh) without a VM: omarchy-mac's 5
# update snapshots become 2 (once) and the extra ones go at once, a number
# set by hand stays (also 5 after the change), the weekly trim is on and a
# trim starts; guest/install.sh runs it at every full apply; omacvm check's
# "freeing disk space" line.
# snapper, systemctl and findmnt are stand-ins.
#   src/tests/disk-space.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/src/guest/disk-space.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# snapper: set-config writes KEY=VALUE into the config ($SNAPPER_FAIL: fails)
cat > "$T/bin/snapper" <<'EOF'
#!/bin/bash
echo "snapper $*" >> "$CALLS"
[[ -z ${SNAPPER_FAIL:-} ]] || exit 1
[[ $1 == -c && $2 == root ]] || exit 2
if [[ $3 == set-config ]]; then
  shift 3
  for kv in "$@"; do
    k=${kv%%=*}
    sed "s/^$k=.*/$k=\"${kv#*=}\"/" "$OMACVM_SNAPPER_ROOT" > "$OMACVM_SNAPPER_ROOT.new" &&
      mv "$OMACVM_SNAPPER_ROOT.new" "$OMACVM_SNAPPER_ROOT"
  done
fi
exit 0
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
[[ $* == "is-enabled -q fstrim.timer" ]] && exit "${TIMER_OFF:-0}"
exit 0
EOF
cat > "$T/bin/findmnt" <<'EOF'
#!/bin/bash
echo "$ROOT_OPTS"
EOF
chmod +x "$T/bin/"*
export PATH=$T/bin:$PATH CALLS=$T/calls OMACVM_SNAPPER_ROOT=$T/root OMACVM_SNAPPER_DONE=$T/lib/omacvm/update-snapshots
config() {   # NUMBER_LIMIT NUMBER_LIMIT_IMPORTANT: omarchy-mac's file
  printf '%s\n' '# Omarchy snapshots root only for pre-update recovery — kept to 5, no timeline' \
    'SUBVOLUME="/"' 'FSTYPE="btrfs"' '' 'NUMBER_CLEANUP="yes"' 'NUMBER_MIN_AGE="0"' \
    "NUMBER_LIMIT=\"$1\"" "NUMBER_LIMIT_IMPORTANT=\"$2\"" '' 'TIMELINE_CREATE="no"' > "$T/root"
}
limits() { grep -E '^NUMBER_LIMIT' "$T/root" | tr '\n' ' '; }
run() { : > "$CALLS"; out=$(bash "$S" 2>&1); rc=$?; calls=$(tr '\n' ';' < "$CALLS"); }
TRIM="systemctl enable fstrim.timer;systemctl start --no-block fstrim.service;"

config 5 5; run
expect "omarchy-mac's 5: exit 0" 0 "$rc"
expect "omarchy-mac's 5: 2 kept" 'NUMBER_LIMIT="2" NUMBER_LIMIT_IMPORTANT="2" ' "$(limits)"
expect "omarchy-mac's 5: set, the extra snapshots go at once, timer on, a trim" \
  "snapper -c root set-config NUMBER_LIMIT=2 NUMBER_LIMIT_IMPORTANT=2;snapper -c root cleanup number;$TRIM" "$calls"
expect "omarchy-mac's 5: says so" "update snapshots: the last 2 kept (were 5)" "$out"

expect "omarchy-mac's 5: done once" yes "$([[ -e $OMACVM_SNAPPER_DONE ]] && echo yes)"

run
expect "again: snapper untouched, timer and trim only" "$TRIM" "$calls"
expect "again: says nothing" "" "$out"

config 3 3; run
expect "a number set by hand: stays" 'NUMBER_LIMIT="3" NUMBER_LIMIT_IMPORTANT="3" ' "$(limits)"
expect "a number set by hand: snapper untouched" "$TRIM" "$calls"

config 5 5; run
expect "5 set by hand after the change: stays" 'NUMBER_LIMIT="5" NUMBER_LIMIT_IMPORTANT="5" ' "$(limits)"
expect "5 set by hand after the change: snapper untouched" "$TRIM" "$calls"

rm -rf "$T/lib" "$T/root"; run
expect "no snapper (not btrfs, Omarchy by hand): only the trim" "$TRIM" "$calls"
expect "no snapper: exit 0" 0 "$rc"

config 5 5; SNAPPER_FAIL=1 run
expect "snapper fails: no cleanup, the trim still" "snapper -c root set-config NUMBER_LIMIT=2 NUMBER_LIMIT_IMPORTANT=2;$TRIM" "$calls"
expect "snapper fails: says so, exit 0" "update snapshots: could not set the number kept (snapper)|0" "$out|$rc"
expect "snapper fails: tried again next time" no "$([[ -e $OMACVM_SNAPPER_DONE ]] && echo yes || echo no)"

# guest/install.sh: at every full apply, after the initramfs and GRUB.
I=$R/src/guest/install.sh
call=$(grep -n 'bash "$R/guest/disk-space.sh"' "$I" | cut -d: -f1)
stamp=$(grep -n '| install -Dm644 /dev/stdin $BOOT_STAMP' "$I" | cut -d: -f1)
expect "install.sh runs it once" 1 "$(grep -c 'guest/disk-space.sh' "$I")"
expect "install.sh: after the boot files" yes "$( (( ${call:-0} > ${stamp:-0} && ${stamp:-0} > 0 )) && echo yes)"
expect "install.sh: only at a full apply" 'if system; then' "$(sed -n "$((call - 1))p" "$I")"

# omacvm check's line, the block from guest/check.sh with the stand-ins.
blk=$(sed -n '/^# What the VM frees goes back to the Mac/,/^else ok "freeing disk space"/p' "$R/src/guest/check.sh" |
  sed -e "s#/etc/snapper/configs/root#$T/root#" -e "s#/var/lib/omacvm/update-snapshots#$OMACVM_SNAPPER_DONE#")
cat > "$T/check" <<EOF
ok()   { echo "ok|\$1|\$2"; }
bad()  { echo "FAIL|\$1|\$2"; }
warn() { echo "WARN|\$1|\$2"; }
$blk
EOF
chk() { bash "$T/check" 2>&1; }
config 2 2
expect "check: discard, timer, 2 snapshots" "ok|freeing disk space|discard, weekly trim; 2 update snapshots" \
  "$(ROOT_OPTS=rw,noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=/@ chk)"
config 5 5
expect "check: omarchy-mac's 5 (no apply yet)" \
  "WARN|freeing disk space|discard, weekly trim; 5 update snapshots keep deleted system files (omacvm apply keeps 2)" \
  "$(ROOT_OPTS=rw,discard=async chk)"
mkdir -p "${OMACVM_SNAPPER_DONE%/*}"; : > "$OMACVM_SNAPPER_DONE"
expect "check: 5 set by hand after the change" "ok|freeing disk space|discard, weekly trim; 5 update snapshots" \
  "$(ROOT_OPTS=rw,discard=async chk)"
rm -f "$T/root"
expect "check: no snapper, trim only" "ok|freeing disk space|weekly trim" "$(ROOT_OPTS=rw,nodiscard,ssd chk)"
expect "check: nothing trims" "FAIL|freeing disk space|nothing trims: deleted files keep their space (omacvm apply)" \
  "$(ROOT_OPTS=rw,nodiscard TIMER_OFF=1 chk)"

exit $fail
