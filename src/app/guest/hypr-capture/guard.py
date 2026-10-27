#!/usr/bin/env python3
"""Which of OmacVM's shader fixes fits this Hyprland binary (hypr-capture.sh).

    python3 -I guard.py BINARY FOLDER...

Hyprland builds its shader files into its binary. A FOLDER (one per Hyprland
release, e.g. 0.56.2/) fits when the binary names the commit in the folder's
`original` list and carries each file listed there byte for byte. Prints the
first folder that fits and exits 0; exits 1 when none does (why on stderr), 2
when the binary or a list cannot be read. hypr-capture.sh takes anything but 0
as "leave Hyprland's own copy".
"""
import hashlib
import os
import sys


def read_list(path):
    commit, files = None, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            kind, _, rest = line.partition(" ")
            if kind == "commit" and rest:
                commit = rest.encode()
            elif kind == "file":
                sha, size, name, first = rest.split(" ", 3)
                files.append((sha, int(size), name, first.encode()))
            else:
                raise ValueError(f"{path}: cannot read {line!r}")
    if not commit or not files:
        raise ValueError(f"{path}: no commit or no file")
    return commit, files


def carries(data, sha, size, first):
    """The file starts at one of the places where its first line is."""
    pos = data.find(first)
    while pos >= 0:
        if hashlib.sha256(data[pos:pos + size]).hexdigest() == sha:
            return True
        pos = data.find(first, pos + 1)
    return False


def why_not(data, path):
    commit, files = read_list(path)
    if commit not in data:
        return f"not built from commit {commit.decode()[:8]}"
    for sha, size, name, first in files:
        if not carries(data, sha, size, first):
            return f"its {name} is not the one OmacVM's fix is made for"
    return None


def main(argv):
    if len(argv) < 3:
        print("usage: guard.py BINARY FOLDER...", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as f:
            data = f.read()
        reasons = []
        for folder in argv[2:]:
            folder = folder.rstrip("/")
            why = why_not(data, os.path.join(folder, "original"))
            if why is None:
                print(os.path.basename(folder))
                return 0
            reasons.append(f"{os.path.basename(folder)}: {why}")
    except (OSError, ValueError) as e:
        print(f"cannot check: {e}", file=sys.stderr)
        return 2
    print("; ".join(reasons) or "no fix folder", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
