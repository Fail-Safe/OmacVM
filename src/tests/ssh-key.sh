#!/bin/bash
# omacvm apply puts the VM folder's SSH key into root's and the desktop user's
# authorized_keys (src/guest/ssh-key.sh). It wrote the user's ~/.ssh as root
# and followed links there: ~/.ssh -> /etc, or authorized_keys -> a system
# file, gave the user that file at the next apply (root). The user's part now
# runs as the user. Root's ~/.ssh is a folder of the test here.
#   src/tests/ssh-key.sh         stand-ins for getent and runuser (any Mac or Linux)
#   sudo src/tests/ssh-key.sh    on Linux also with a real user and real links
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
LINUX_USER=omacvm-keytest
cleanup() {
  if [[ $(id -u) == 0 ]] && id "$LINUX_USER" >/dev/null 2>&1; then userdel -r "$LINUX_USER" >/dev/null 2>&1; fi
  rm -rf "$T"
}
trap cleanup EXIT
chmod 755 "$T"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
owner() { stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"; }
K="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOmacVMtestKeyOnlyForThisTest0123456789ab omacvm-vm"

# The script with root's ~/.ssh in the test's folder.
sed "s#/root/.ssh#$T/root/.ssh#g" "$R/src/guest/ssh-key.sh" > "$T/ssh-key.sh"
expect "the test's copy differs only in root's folder" "1" "$(grep -c "$T/root/.ssh" "$T/ssh-key.sh")"

# ---------- stand-ins: getent knows "me", runuser drops "-u USER --" ----------
mkdir -p "$T/bin" "$T/home/me"
cat > "$T/bin/getent" <<EOF
#!/bin/bash
[[ \$1 == passwd && \$2 == me ]] && echo "me:x:1000:1000::$T/home/me:/bin/bash"
EOF
cat > "$T/bin/runuser" <<'EOF'
#!/bin/bash
# Records the call; FAKE_RUNUSER=none does nothing, fail fails, else runs the command.
echo "$1 $2 $3" >> "$FAKE_DIR/runuser.log"
case ${FAKE_RUNUSER:-} in none) exit 0 ;; fail) exit 1 ;; esac
shift 3; exec "$@"
EOF
chmod +x "$T/bin/getent" "$T/bin/runuser"
run() {   # KEY [VAR=VALUE...]: output and exit status
  local k=$1; shift
  env PATH="$T/bin:$PATH" FAKE_DIR="$T" "$@" /bin/bash "$T/ssh-key.sh" me "$k" 2>&1; echo "rc=$?"
}
out=$(run "$K")
expect "a key: done" "rc=0" "$out"
expect "... root has it" "$K" "$(cat "$T/root/.ssh/authorized_keys")"
expect "... root's folder 700, file 600" "700 600" "$(mode "$T/root/.ssh") $(mode "$T/root/.ssh/authorized_keys")"
expect "... the user has it" "$K" "$(cat "$T/home/me/.ssh/authorized_keys")"
expect "... the user's folder 700, file 600" "700 600" "$(mode "$T/home/me/.ssh") $(mode "$T/home/me/.ssh/authorized_keys")"
expect "... written through runuser as the user" "-u me --" "$(cat "$T/runuser.log")"
out=$(run "$K")
expect "again: no second line for root" "1" "$(grep -c . "$T/root/.ssh/authorized_keys")"
expect "... nor for the user" "1" "$(grep -c . "$T/home/me/.ssh/authorized_keys")"
printf 'ssh-ed25519 OTHERKEY other-mac\n' > "$T/root/.ssh/authorized_keys"
run "$K" >/dev/null
expect "a key of another Mac stays, ours comes after it" "ssh-ed25519 OTHERKEY other-mac|$K" "$(paste -sd '|' "$T/root/.ssh/authorized_keys")"
rm -rf "$T/root" "$T/home/me/.ssh"
out=$(run "ssh-rsa AAAAB3Nza other")
expect "not an ssh-ed25519 key: refused" "yes" "$([[ $out == *"not an ssh-ed25519 key"*"rc=1" ]] && echo yes || echo "$out")"
expect "... nothing written" "no" "$([[ -e $T/root/.ssh ]] && echo yes || echo no)"
out=$(run "$(printf '%s\nssh-ed25519 BBBB second' "$K")")
expect "two lines: refused" "yes" "$([[ $out == *"not one line"*"rc=1" ]] && echo yes || echo "$out")"
expect "... nothing written" "no" "$([[ -e $T/root/.ssh ]] && echo yes || echo no)"
out=$(run "$K" FAKE_RUNUSER=none)
expect "root writes nothing in the user's home: all of it goes through runuser" "no" "$([[ -e $T/home/me/.ssh ]] && echo yes || echo no)"
out=$(run "$K" FAKE_RUNUSER=fail)
expect "the user's part fails: a warning, apply goes on" "yes" "$([[ $out == *"warning: the key did not go into me's"*"rc=0" ]] && echo yes || echo "$out")"
expect "apply sends this script with the user and the key as arguments" "1" \
  "$(grep -c "gssh \"\$IP\" \"bash -s -- '\$U' '\$pubkey'\" < \"\$R/src/guest/ssh-key.sh\"" "$R/src/cmd/apply.sh")"

# ---------- Linux as root: a real user, real links ----------
if [[ $(id -u) != 0 || $(uname) != Linux ]] || ! command -v useradd >/dev/null || ! command -v runuser >/dev/null; then
  echo "skip the real user's links (Linux as root only: sudo $0)"
  exit $fail
fi
useradd -m -s /bin/bash "$LINUX_USER" || { echo "FAIL useradd"; exit 1; }
H=$(getent passwd "$LINUX_USER" | cut -d: -f6)
lrun() { /bin/bash "$T/ssh-key.sh" "$LINUX_USER" "$K" 2>&1; echo "rc=$?"; }
# ~/.ssh is a link to a folder of the system.
mkdir -p "$T/sys"; chmod 755 "$T/sys"; echo "root's" > "$T/sys/keep"
ln -s "$T/sys" "$H/.ssh"; chown -h "$LINUX_USER:" "$H/.ssh"
out=$(lrun)
expect "~/.ssh -> a system folder: apply goes on" "yes" "$([[ $out == *"rc=0" ]] && echo yes || echo "$out")"
expect "... the folder stays root's, 755" "root 755" "$(owner "$T/sys") $(mode "$T/sys")"
expect "... no authorized_keys in it" "no" "$([[ -e $T/sys/authorized_keys ]] && echo yes || echo no)"
expect "... root's own file still has the key" "$K" "$(cat "$T/root/.ssh/authorized_keys")"
rm -f "$H/.ssh"
# ~/.ssh/authorized_keys is a link to a file of the system.
mkdir -m 700 "$H/.ssh"; chown "$LINUX_USER:" "$H/.ssh"
echo "a system file" > "$T/sys/file"; chmod 644 "$T/sys/file"
ln -s "$T/sys/file" "$H/.ssh/authorized_keys"; chown -h "$LINUX_USER:" "$H/.ssh/authorized_keys"
out=$(lrun)
expect "authorized_keys -> a system file: apply goes on" "yes" "$([[ $out == *"rc=0" ]] && echo yes || echo "$out")"
expect "... the file is unchanged, root's, 644" "a system file root 644" "$(cat "$T/sys/file") $(owner "$T/sys/file") $(mode "$T/sys/file")"
rm -f "$H/.ssh/authorized_keys"
# No links: the user's own file.
out=$(lrun)
expect "a plain home: the user's file has the key" "$K" "$(cat "$H/.ssh/authorized_keys")"
expect "... the user's, 700 and 600" "$LINUX_USER 700 $LINUX_USER 600" \
  "$(owner "$H/.ssh") $(mode "$H/.ssh") $(owner "$H/.ssh/authorized_keys") $(mode "$H/.ssh/authorized_keys")"
exit $fail
