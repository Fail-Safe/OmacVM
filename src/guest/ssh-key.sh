#!/bin/bash
# The VM folder's SSH key for root and the desktop user (omacvm apply runs it
# as root with bash -s: OmacVM's own files are not in the VM yet).
#   guest/ssh-key.sh USER 'ssh-ed25519 KEY [COMMENT]'
# The user's ~/.ssh is written as the user (runuser). Written as root, a link
# the user put there (~/.ssh -> /etc) would point the write, chown and chmod
# at a file of the system: root at the next apply. As the user it reaches
# only what the user may change anyway.
set -euo pipefail
U=${1:?usage: ssh-key.sh USER KEY}
k=${2:?usage: ssh-key.sh USER KEY}
case $k in "ssh-ed25519 "*) ;; *) echo "not an ssh-ed25519 key" >&2; exit 1 ;; esac
[[ $k != *[$'\n\r']* ]] || { echo "the key is not one line" >&2; exit 1; }

# add DIR KEY: KEY once into DIR/authorized_keys (700, 600), as whoever runs it.
add() {
  umask 077
  mkdir -p "$1" && chmod 700 "$1" && touch "$1/authorized_keys" &&
    { grep -qxF -- "$2" "$1/authorized_keys" || printf '%s\n' "$2" >> "$1/authorized_keys"; } &&
    chmod 600 "$1/authorized_keys"
}
cd /
add /root/.ssh "$k"
H=$(getent passwd "$U" | cut -d: -f6) || H=""
[[ -n $H && -d $H && $U != root ]] || exit 0
runuser -u "$U" -- /bin/bash -c "$(declare -f add); add \"\$@\"" add "$H/.ssh" "$k" ||
  echo "warning: the key did not go into $U's ~/.ssh/authorized_keys (not writable by $U)" >&2
