# shellcheck shell=bash
# Changes in the desktop user's home, made as that user. Sourced by the guest
# scripts that run as root (guest/install.sh, off.sh, the features' install
# scripts, lib/install-plugin.sh); they set U (the user) and H (the home).
#
# Root writing in a home follows the links its owner put there: with
# ~/.config/hypr -> /etc, or hyprland.lua -> /etc/shadow, root's write, chown
# or chmod lands on a file of the system, and a program running as the user
# gets root at the next apply (#465 did this for ~/.ssh). Done as the user, a
# link reaches only what the user may change anyway. Content that goes back
# into the home is read as the user too: root would copy a system file into
# the user's file through a link. Content to write comes on stdin, opened by
# the caller (root). Paths are absolute. Not run as root (the tests on a Mac):
# done as whoever runs it.

# home_run CMD...: CMD as the user, in /, with the user's HOME, USER and
# LOGNAME. setpriv, not runuser or sudo: no login session (PAM), nothing in
# the journal, also before systemd-user-sessions; root's capabilities go with
# root's user id. setsid: no controlling terminal, so a terminal root ran
# this from takes no keys from it (TIOCSTI).
home_run() {
  if (( EUID != 0 )); then "$@"; return; fi
  local g; g=$(id -g "$U") || return 1
  ( cd / && exec setsid -w setpriv --reuid="$U" --regid="$g" --init-groups -- \
      env HOME="$H" USER="$U" LOGNAME="$U" "$@" )
}

# home_claim DIR...: the folders of root's on the way from the home to DIR
# become the user's. Older versions made them with root's install -d -o, which
# leaves the folders above the last one root's (~/.config/systemd/user), and
# the user could not write there. Walked from the home one folder at a time,
# none of them through a link (O_NOFOLLOW below an open folder), so nothing
# can be swapped in between; only below ~/.config, ~/.local and ~/.cache, in
# a home of the user's own, on the home's file system.
home_claim() {
  (( EUID == 0 )) || return 0
  python3 -I - "$H" "$U" "$@" <<'PY' || true
import os, pwd, sys
home, user, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
pw = pwd.getpwnam(user)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
for d in dirs:
    rel = d[len(home) + 1:].split("/") if d.startswith(home + "/") else []
    if not rel or rel[0] not in (".config", ".local", ".cache"):
        continue
    fd = os.open(home, flags)
    try:
        top = os.fstat(fd)
        if top.st_uid != pw.pw_uid:
            continue
        for name in rel:
            if name in ("", ".", ".."):
                break
            try:
                sub = os.open(name, flags, dir_fd=fd)
            except OSError:   # not there, a link or no folder: the user makes the rest
                break
            os.close(fd)
            fd = sub
            st = os.fstat(fd)
            if st.st_dev != top.st_dev:
                break
            if st.st_uid == 0:
                os.fchown(fd, pw.pw_uid, pw.pw_gid)
    finally:
        os.close(fd)
PY
}

# home_mkdir DIR...: folders, with the missing ones above them (mkdir -p).
home_mkdir() { home_claim "$@"; home_run mkdir -p -- "$@" < /dev/null; }

# home_put FILE [MODE]: stdin as FILE, in one step: written beside it, then
# renamed into place (a link at FILE is replaced, never followed). MODE 644.
home_put() {
  home_run /bin/bash -c 'set -e; t=$(mktemp "$1.XXXXXX"); trap '\''rm -f "$t"'\'' EXIT
    cat > "$t"; chmod "$2" "$t"; mv -f "$t" "$1"; trap - EXIT' _ "$1" "${2:-644}"
}

# home_append FILE: stdin at the end of FILE (made when missing). A FILE the
# user cannot write (root left it there) is replaced: its content, then stdin.
home_append() {
  home_run /bin/bash -c 'if [ ! -e "$1" ] || [ -w "$1" ]; then exec cat >> "$1"; fi
    set -e; t=$(mktemp "$1.XXXXXX"); trap '\''rm -f "$t"'\'' EXIT
    { cat -- "$1" 2>/dev/null || true; cat; } > "$t"; chmod 644 "$t"; mv -f "$t" "$1"; trap - EXIT' _ "$1"
}

# home_write FILE: stdin as FILE's new content, in place (owner and mode kept;
# a FILE the user cannot write is replaced, as in home_append).
home_write() {
  home_run /bin/bash -c 'if [ ! -e "$1" ] || [ -w "$1" ]; then exec cat > "$1"; fi
    set -e; t=$(mktemp "$1.XXXXXX"); trap '\''rm -f "$t"'\'' EXIT
    cat > "$t"; chmod 644 "$t"; mv -f "$t" "$1"; trap - EXIT' _ "$1"
}

# home_cat FILE: FILE's content, read as the user (status 1, nothing printed,
# when the user cannot read it).
home_cat() { home_run cat -- "$1" 2>/dev/null < /dev/null; }

# home_same FILE NEW: FILE has the content of NEW (a file of root's).
home_same() { home_cat "$1" | cmp -s - "$2"; }

# home_grep FILE GREP-ARGS...: grep in FILE, read as the user (grep's status:
# no pipe, so an early grep -q is no failure under pipefail).
home_grep() { local f=$1; shift; grep "$@" < <(home_cat "$f"); }
