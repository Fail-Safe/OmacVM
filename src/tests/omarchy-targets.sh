#!/usr/bin/env bash
# omarchy-mac's ARM package targets (omacom/omarchy-mac#741), offline:
# guest/omarchy-targets.sh on a copy of omarchy-mac's arm-package-sources.sh
# (its targets and upgrade arguments as of 2026-10), with a made-up pacman
# that lists the [omarchy] repo. Needs bash 4+ (the file uses mapfile): on the
# Mac Homebrew's bash, else it skips.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$R/src/guest/omarchy-targets.sh"
if (( BASH_VERSINFO[0] < 4 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x $b ]] && exec "$b" "$0" "$@"; done
  echo "skip: bash 4+ needed"; exit 0
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-targets.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
t() {  # want got name
  if [[ $2 == "$1" ]]; then echo "ok   $3"; else echo "FAIL $3: want '$1', got '$2'"; fail=1; fi
}

# omarchy-mac's functions (install/helpers/arm-package-sources.sh, shortened).
cat > "$T/orig.sh" <<'EOF'
#!/bin/bash

# Shared by the standalone installer and installed package update commands.
omarchy_arm_package_targets() {
  printf '%s\n' omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils
}

omarchy_arm_package_upgrade_args() {
  local target package names=() targets=()
  mapfile -t targets < <(omarchy_arm_package_targets)
  for package in asdcontrol tobi-try; do
    if pacman --config "${OMARCHY_PACMAN_CONFIG:-/etc/pacman.conf}" -Q "$package" >/dev/null 2>&1; then
      targets+=("omarchy/$package")
    fi
  done
  for target in "${targets[@]}"; do names+=("${target#*/}"); done
  local IFS=,
  printf '%s\n' --ignore "${names[*]}" "${targets[@]}"
}

omarchy_arm_package_is_selected() {
  local target
  while read -r target; do
    [[ ${target#*/} == "$1" ]] && return 0
  done < <(omarchy_arm_package_targets)
  return 1
}
EOF

# pacman: -Sl omarchy prints $FAKE_SL (unset: the repo is unknown, exit 1);
# every call is logged.
mkdir "$T/bin"
cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
echo "$*" >> "$PACLOG"
case " $* " in
  *" -Sl omarchy "*) [[ -n ${FAKE_SL+x} ]] || { echo "error: repository 'omarchy' was not found" >&2; exit 1; }; printf '%s' "$FAKE_SL" ;;
  *" -Q "*) exit 1 ;;
esac
EOF
chmod +x "$T/bin/pacman"
export PATH="$T/bin:$PATH" PACLOG="$T/pacman.log"

F="$T/arm-package-sources.sh"
cp "$T/orig.sh" "$F"
t "not patched" "$("$BASH" "$FIX" --status "$F")" "status before"
"$BASH" "$FIX" "$F" >/dev/null
t patched "$("$BASH" "$FIX" --status "$F")" "status after"
cp "$F" "$T/once"
"$BASH" "$FIX" "$F" >/dev/null
cmp -s "$F" "$T/once"; t 0 $? "a second run changes nothing"

# One shell as the updater runs it (set -euo pipefail), the patched file sourced.
run() {  # what: targets | args | selected NAME
  "$BASH" -c 'set -euo pipefail; source "$1"; case $2 in
    targets) omarchy_arm_package_targets ;;
    args) omarchy_arm_package_upgrade_args ;;
    selected) omarchy_arm_package_is_selected "$3" && echo yes || echo no ;;
  esac | tr "\n" " "' _ "$F" "$@"
}
ALL="omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils "

export FAKE_SL=$'omarchy hyprland 0.56.2-7\nomarchy aquamarine 0.15.1-1.3\nomarchy omarchy 4.0.5-1\n'
t "omarchy/hyprland " "$(run targets)" "repo without hyprtoolkit and hyprland-guiutils: hyprland only"
t "--ignore hyprland omarchy/hyprland " "$(run args)" "  pacman's arguments ignore only hyprland"
t "no " "$(run selected hyprland-guiutils)" "  hyprland-guiutils not selected (yay installs it from ALARM)"

FAKE_SL=$'omarchy hyprland 0.56.2-7\nomarchy hyprtoolkit 0.6.0-1\nomarchy hyprland-guiutils 0.2.2-4\n'
t "$ALL" "$(run targets)" "repo with all three: upstream's targets"
t "--ignore hyprland,hyprtoolkit,hyprland-guiutils $ALL" "$(run args)" "  upstream's arguments"

FAKE_SL=$'omarchy hyprland 0.56.2-7\nomarchy hyprland-guiutils 0.2.2-4\n'
t "omarchy/hyprland omarchy/hyprland-guiutils " "$(run targets)" "repo with one of the two: that one"

unset FAKE_SL
t "$ALL" "$(run targets)" "repo list unreadable (pacman fails, pipefail): upstream's targets"
export FAKE_SL=""
t "$ALL" "$(run targets)" "empty repo list: upstream's targets"

# The channel installer's probe: its config and db, not the system's.
FAKE_SL=$'omarchy hyprland 0.56.2-7\n'
: > "$PACLOG"
got=$("$BASH" -c 'set -euo pipefail; source "$1"
  prep() { local -a probe=(--config /stage/resolved.conf --dbpath /stage/db --cachedir /stage/cache --gpgdir /stage/keyring --logfile /stage/l)
    omarchy_arm_package_upgrade_args; }
  prep | tr "\n" " "' _ "$F")
t "--ignore hyprland omarchy/hyprland " "$got" "installer's probe: hyprland only"
t "--config /stage/resolved.conf --dbpath /stage/db -Sl omarchy" "$(grep -- '-Sl' "$PACLOG")" "  pacman read the probe's config and db"
: > "$PACLOG"
OMARCHY_PACMAN_CONFIG=/x/pacman.conf run targets >/dev/null
t "--config /x/pacman.conf -Sl omarchy" "$(grep -- '-Sl' "$PACLOG")" "OMARCHY_PACMAN_CONFIG: that config"

# Sourced twice (the updater's scripts each source it): still one wrapper deep.
got=$("$BASH" -c 'set -euo pipefail; source "$1"; source "$1"; omarchy_arm_package_targets | tr "\n" " "' _ "$F")
t "omarchy/hyprland " "$got" "sourced twice"

# An older block (another OmacVM version) is replaced, not added to.
sed 's/^# from Arch Linux ARM\./# from Arch Linux ARM (old)./' "$T/once" > "$F"
t "not patched" "$("$BASH" "$FIX" --status "$F")" "an older block: not patched"
"$BASH" "$FIX" "$F" >/dev/null
cmp -s "$F" "$T/once"; t 0 $? "  replaced by the current one"
t 1 "$(grep -c '^# >>> omacvm omarchy-targets' "$F")" "  one block"

"$BASH" "$FIX" --restore "$F" >/dev/null
cmp -s "$F" "$T/orig.sh"; t 0 $? "--restore: upstream's file again"

printf '#!/bin/bash\nsomething_else() { :; }\n' > "$T/other.sh"; cp "$T/other.sh" "$T/other.orig"
t "not needed" "$("$BASH" "$FIX" --status "$T/other.sh")" "a file without the targets function: not needed"
"$BASH" "$FIX" "$T/other.sh" >/dev/null
cmp -s "$T/other.sh" "$T/other.orig"; t 0 $? "  left as it is"
t "not needed" "$("$BASH" "$FIX" --status "$T/missing.sh")" "a missing file: not needed"

exit $fail
