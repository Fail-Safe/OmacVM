#!/bin/bash
# cc-switches.sh's "is the VM's package list older than the mirrors" check, without a VM: its
# mirrors_current() run here against made-up sync databases and a made-up mirror (stand-ins
# for pacman, pacman-conf and curl; the mirror is a folder). A test VM whose list is older
# than the mirrors gets `omarchy update -y` first; when the check misses it, OmacVM's own packages are a 404 and the
# update pass's switch rows fail for the harness, not the product (3.2.3's gate: jq's file was
# still on the mirror, Mesa's build tools were not).
#   src/tests/e2e-mirrors.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
H=$R/src/tests/e2e/cc-switches.sh
fail=0
W=$(mktemp -d "${TMPDIR:-/tmp}/e2e-mirrors.XXXXXX")
trap 'rm -rf "$W"' EXIT
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The function as the harness has it.
awk '/^mirrors_current\(\) \{/ {f = 1} f {print} f && /^\}/ {exit}' "$H" > "$W/fn.sh"
[[ -s $W/fn.sh ]] || { echo "FAIL mirrors_current() not found in $H"; exit 1; }
# shellcheck disable=SC1091
. "$W/fn.sh"
# The VM: its commands run here, with the stand-ins first in PATH.
gssh() { PATH="$W/bin:$PATH" bash -c "$1" < /dev/null; }

mkdir -p "$W/bin" "$W/vm/sync" "$W/mirror/core" "$W/mirror/extra"
cat > "$W/bin/pacman-conf" <<EOF
#!/bin/bash
case \$1 in
  DBPath) echo "$W/vm/" ;;
  -r|--repo) [[ -f $W/norepo-\$2 ]] || echo "http://mirror.test/aarch64/\$2" ;;
esac
EOF
# pacman -Sp: the URL of a package from the VM's list (jq stays the same version throughout).
cat > "$W/bin/pacman" <<EOF
#!/bin/bash
[[ " \$* " == *" -Sp "* || " \$* " == *" --print "* ]] && echo "http://mirror.test/aarch64/extra/jq-1.8.1-1-aarch64.pkg.tar.xz"
exit 0
EOF
# curl: http://mirror.test/aarch64/X is $W/mirror/X; missing = a 404 (exit 22, as with -f).
cat > "$W/bin/curl" <<EOF
#!/bin/bash
o=""; u=""
while (( \$# )); do
  case \$1 in
    -o) o=\$2; shift 2 ;;
    http://*) u=\$1; shift ;;
    *) shift ;;
  esac
done
f=$W/mirror/\${u#http://mirror.test/aarch64/}
[[ \$u == http://mirror.test/aarch64/* && -f \$f ]] || exit 22
[[ -z \$o ]] || cp "\$f" "\$o"
EOF
chmod +x "$W/bin/pacman-conf" "$W/bin/pacman" "$W/bin/curl"
: > "$W/mirror/extra/jq-1.8.1-1-aarch64.pkg.tar.xz"
lists() {   # CORE EXTRA: the mirror's package lists now
  printf '%s\n' "$1" > "$W/mirror/core/core.db"
  printf '%s\n' "$2" > "$W/mirror/extra/extra.db"
}
sync_vm() { cp "$W/mirror/core/core.db" "$W/mirror/extra/extra.db" "$W/vm/sync/"; }
check() { if mirrors_current > "$W/why" 2>&1; then echo current; else echo older; fi; }

lists "core 1" "extra 1 jq-1.8.1 meson-1.9.0"; sync_vm
expect "the VM's lists are the mirrors' lists" current "$(check)"

lists "core 1" "extra 2 jq-1.8.1 meson-1.9.1"
expect "the mirror has a newer extra list (meson), jq's file still there" older "$(check)"
expect "  ... and says which list" "extra" "$(grep -o extra "$W/why" | head -1)"

sync_vm; lists "core 2" "extra 2 jq-1.8.1 meson-1.9.1"
expect "the mirror has a newer core list" older "$(check)"

sync_vm; rm -f "$W/mirror/extra/extra.db"
expect "a mirror that does not answer: not current" older "$(check)"

lists "core 2" "extra 2 jq-1.8.1 meson-1.9.1"; touch "$W/norepo-extra"
expect "a list without a mirror: not current" older "$(check)"
rm -f "$W/norepo-extra"

rm -f "$W/vm/sync/"*.db
expect "a VM that has no package lists: not current" older "$(check)"

if (( fail )); then echo "e2e-mirrors: FAIL"; exit 1; fi
echo "e2e-mirrors: all ok"
