#!/usr/bin/env python3
"""Omarchy's shell colours on Qt 6.12 (#376).

usage: shell-colors.py [--revert | --status] [--user NAME] [--qmltypes FILE] [PATH ...]

Qt 6.12 brought a singleton of its own named Color into QtQuick (rgba(),
lighter(), ...). Omarchy's shell has its Color singleton in qs.Commons, and
its files import both. A plain `import QtQuick` is QtQuick's newest version,
so there a bare `Color` is QtQuick's, whatever the import order: every colour
the shell reads (Color.bar.text, Color.foreground, ...) is undefined, and the
bar, menus, OSD and notifications draw empty.

QtQuick imported with a version below the one that brought Color leaves it
out (`import QtQuick 6.11`); on Qt 6.11 that is the same as the plain import.
So in every QML file that imports plain QtQuick and uses Omarchy's bare
Color (and none of QtQuick's Color functions), that line gets the version,
marked as OmacVM's. Only while the installed QtQuick has Color: on a Qt
without it the marked lines go back to the plain import. A file Omarchy
changed so that it no longer matches (a versioned or qualified import, no
bare Color) is left as it is, so the fix drops away by itself.

PATH: files or folders (searched for *.qml, and Omanotch's unpatched copies
*.qml.before-notchbar, which its bar and background patches start from).
Default: /usr/share/omarchy/shell and the desktop user's
~/.config/omarchy/plugins (clones of Omarchy's plugins); --user NAME, else
OMACVM_USER from /etc/omacvm/env. Owner and mode of each file are kept.

Prints one line: "patched N files (QtQuick X.Y)", "restored N files",
"nothing to do (...)". --status writes nothing and prints "qtquick-color
yes|no|unknown, patched N, to patch M, to restore K". Exit 1 when a file
could not be written.
"""
import os
import pwd
import re
import sys

QMLTYPES = "/usr/lib/qt6/qml/QtQuick/plugins.qmltypes"
OMARCHY_SHELL = "/usr/share/omarchy/shell"
ENV = "/etc/omacvm/env"
MARK = "// omacvm #376: QtQuick's own Color (Qt 6.12) would hide Omarchy's"

PLAIN = re.compile(r"^import[ \t]+QtQuick[ \t]*;?[ \t]*$", re.M)
PATCHED = re.compile(r"^import QtQuick \d+\.\d+ " + re.escape(MARK) + r"[ \t]*$", re.M)
# Omarchy's Color, not a member (x.Color) or another name (MyColor).
BARE_COLOR = re.compile(r"(?<![\w.$])Color\s*\.\s*[A-Za-z_]")
# QtQuick's Color (QQuickColor's functions): such a file means Qt's.
QT_COLOR = re.compile(r"(?<![\w.$])Color\s*\.\s*(rgba|hsla|hsva|fromString|equal|lighter|darker|tint|blend|transparent)\s*\(")
EXPORT = re.compile(r'"QtQuick/Color (\d+)\.(\d+)"')


def qtquick_color(path):
    """(major, minor) QtQuick's Color came with, None without it, "unknown" if unreadable."""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return "unknown"
    if "QtQuick/" not in text:
        return "unknown"
    m = EXPORT.search(text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def pin_for(version):
    """The QtQuick version to import: the one before Color's."""
    major, minor = version
    return f"{major}.{minor - 1}" if minor > 0 else f"{major - 1}.0"


def wants_pin(text):
    return bool(PLAIN.search(text)) and bool(BARE_COLOR.search(text)) and not QT_COLOR.search(text)


def change(text, pin):
    """The file's new text (pin = None: back to the plain import)."""
    if pin is None:
        return PATCHED.sub("import QtQuick", text)
    # An older pin first, then the plain imports of a file that needs it.
    text = PATCHED.sub(f"import QtQuick {pin} {MARK}", text)
    if wants_pin(text):
        text = PLAIN.sub(f"import QtQuick {pin} {MARK}", text)
    return text


def files(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
        elif os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs.sort()
                for n in sorted(names):
                    if n.endswith(".qml") or n.endswith(".qml.before-notchbar"):
                        yield os.path.join(root, n)


def write(path, text):
    st = os.stat(path)
    tmp = path + ".omacvm-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        os.chmod(tmp, st.st_mode & 0o7777)
        if os.geteuid() == 0:
            os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    except OSError:
        os.unlink(tmp)
        raise


def default_paths(user):
    if not user:
        try:
            for line in open(ENV):
                if line.startswith("OMACVM_USER="):
                    user = line.split("=", 1)[1].strip()
        except OSError:
            pass
    paths = [OMARCHY_SHELL]
    if user:
        try:
            paths.append(os.path.join(pwd.getpwnam(user).pw_dir, ".config/omarchy/plugins"))
        except KeyError:
            pass
    return paths


def main(argv):
    mode, user, qmltypes, paths = "apply", "", QMLTYPES, []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--revert", "--status"):
            mode = a[2:]
        elif a in ("--user", "--qmltypes") and args:
            v = args.pop(0)
            if a == "--user":
                user = v
            else:
                qmltypes = v
        elif a.startswith("-"):
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 2
        else:
            paths.append(a)
    paths = paths or default_paths(user)

    color = qtquick_color(qmltypes)
    if mode == "revert":
        pin = None
    elif color == "unknown":
        pin = "keep"   # Qt's types not readable: change nothing
    else:
        pin = pin_for(color) if color else None

    patched = todo = restore = failed = 0
    changed = []
    for path in files(paths):
        try:
            text = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        if PATCHED.search(text):
            patched += 1
        if pin == "keep":
            continue
        new = change(text, pin)
        if new == text:
            continue
        if pin is None:
            restore += 1
        else:
            todo += 1
        if mode != "status":
            try:
                write(path, new)
                changed.append(path)
            except OSError as e:
                failed += 1
                print(f"shell-colors: {path}: {e.strerror}", file=sys.stderr)

    if mode == "status":
        state = "unknown" if color == "unknown" else ("yes" if color else "no")
        print(f"qtquick-color {state}, patched {patched}, to patch {todo}, to restore {restore}")
        return 0
    n = len(changed)
    if pin == "keep":
        print(f"nothing to do (QtQuick's types not found: {qmltypes})")
    elif n and pin is None:
        print(f"restored {n} file{'s' * (n != 1)}")
    elif n:
        print(f"patched {n} file{'s' * (n != 1)} (QtQuick {pin})")
    else:
        why = "Qt has no QtQuick Color" if pin is None else f"QtQuick {pin} already where needed"
        print(f"nothing to do ({why})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
