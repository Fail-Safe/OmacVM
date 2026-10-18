#!/bin/bash
# omarchy-targets.sh (in the VM): omarchy-mac's installer and omarchy update
# ask Omarchy's own package repo ([omarchy], pkgs.omarchy.org) for hyprland,
# hyprtoolkit and hyprland-guiutils by name (omarchy/hyprtoolkit). Since
# 2026-10-18 that repo has only hyprland for ARM, so a fresh install and
# omarchy update stop with "target not found" (omacom/omarchy-mac#741).
# This adds a block to omarchy-mac's arm-package-sources.sh: a target the
# synced [omarchy] repo does not have is left out, and pacman takes Arch Linux
# ARM's build of it (built against the same library versions as Omarchy's
# hyprland). While the repo has them, or its list cannot be read, the targets
# stay upstream's. Updates replace the file: the pacman hook patches it again.
#   omarchy-targets.sh [FILE...]        patch FILE (default: the installed Omarchy's); idempotent
#   omarchy-targets.sh --hook           the pacman hook, then the installed Omarchy's file (root)
#   omarchy-targets.sh --restore FILE   the block out again (the install's git checkout)
#   omarchy-targets.sh --status [FILE]  patched | not patched | not needed
# Test: src/tests/omarchy-targets.sh
set -uo pipefail
DEFAULT=/usr/share/omarchy/install/helpers/arm-package-sources.sh
SELF=/usr/local/lib/omacvm/omarchy-targets.sh
HOOK=/etc/pacman.d/hooks/zz-omacvm-omarchy-targets.hook
BEGIN="# >>> omacvm omarchy-targets (omacom/omarchy-mac#741)"
END="# <<< omacvm omarchy-targets"

block() {
  cat <<'EOF'
# Added by OmacVM (/usr/local/lib/omacvm/omarchy-targets.sh): only the
# omarchy/NAME targets the synced [omarchy] repo has; pacman takes the others
# from Arch Linux ARM. A repo list it cannot read: all of them, as upstream.
if ! declare -F omacvm_upstream_arm_package_targets >/dev/null; then
  eval "omacvm_upstream_arm_package_targets() $(declare -f omarchy_arm_package_targets | tail -n +2)"
fi
omarchy_arm_package_targets() {
  local t have i a=()
  # The channel installer's own pacman (its probe: config and db), else the system's.
  if [[ $(declare -p probe 2>/dev/null) == "declare -a"* ]]; then
    for ((i = 0; i + 1 < ${#probe[@]}; i++)); do
      case ${probe[i]} in --config | --dbpath) a+=("${probe[i]}" "${probe[i + 1]}") ;; esac
    done
  elif [[ -n ${OMARCHY_PACMAN_CONFIG:-} ]]; then
    a=(--config "$OMARCHY_PACMAN_CONFIG")
  fi
  have=$(pacman ${a[@]+"${a[@]}"} -Sl omarchy 2>/dev/null | awk '{ print $2 }') || have=""
  while read -r t; do
    if [[ -n $have && $t == omarchy/* ]] && ! grep -qxF "${t#omarchy/}" <<<"$have"; then continue; fi
    printf '%s\n' "$t"
  done < <(omacvm_upstream_arm_package_targets)
}
EOF
}

# The file without our block.
strip() { awk -v b="$BEGIN" -v e="$END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1"; }

status() {
  local f=${1:-$DEFAULT}
  if [[ ! -f $f ]] || ! grep -q '^omarchy_arm_package_targets()' "$f"; then echo "not needed"
  elif cmp -s <({ strip "$f"; echo "$BEGIN"; block; echo "$END"; }) "$f"; then echo patched
  else echo "not patched"; fi
}

# Written in place (owner and mode stay); nothing when it is already so.
patch_file() {
  local f=$1 t
  case $(status "$f") in
    patched) echo "patched already: $f"; return 0 ;;
    "not needed") echo "not needed: $f"; return 0 ;;
  esac
  t=$(mktemp) || return 1
  { strip "$f" && echo "$BEGIN" && block && echo "$END"; } > "$t" && cat "$t" > "$f" && echo "patched: $f"
  local rc=$?; rm -f "$t"; return $rc
}

restore_file() {
  local f=$1 t
  grep -qxF "$BEGIN" "$f" 2>/dev/null || return 0
  t=$(mktemp) || return 1
  strip "$f" > "$t" && cat "$t" > "$f" && echo "restored: $f"
  local rc=$?; rm -f "$t"; return $rc
}

case ${1:-} in
  --status) status "${2:-}" ;;
  --restore) shift; for f in "$@"; do restore_file "$f" || exit 1; done ;;
  --hook)
    [[ $0 -ef $SELF ]] || install -Dm755 "$0" "$SELF" || exit 1
    install -Dm644 /dev/stdin "$HOOK" <<'HOOK' || exit 1
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/share/omarchy/install/helpers/arm-package-sources.sh

[Action]
Description = OmacVM: Omarchy's ARM package targets its repo has (omarchy-mac#741)
When = PostTransaction
Exec = /usr/local/lib/omacvm/omarchy-targets.sh
HOOK
    patch_file "$DEFAULT" ;;
  "") patch_file "$DEFAULT" ;;
  *) for f in "$@"; do patch_file "$f" || exit 1; done ;;
esac
