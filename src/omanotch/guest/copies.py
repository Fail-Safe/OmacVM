#!/usr/bin/env python3
"""Omanotch's copies of Omarchy's bar and background follow Omarchy's updates.

usage: copies.py [--install]   follow Omarchy now (install.sh; --install also
                               makes a copy that is missing)
       copies.py --wait        the same once pacman, `omarchy update` and the
                               lock screen are done (omanotch-copies.service,
                               started at login and by OmacVM's pacman hook)
       copies.py --check       one line per copy for omacvm check:
                               status<TAB>name<TAB>detail (status ok or warn)

Omanotch runs Omarchy's bar and background as copies in
~/.config/omarchy/plugins ($USER.bar, $USER.background: Omarchy's own way to
change a built-in plugin, `omarchy plugin clone`), with its patch in Bar.qml
and Background.qml. Omarchy updates its own plugins the git way
(omarchy-plugin-update): fast-forward only, your changes stay when they do not
touch what comes in, the update is refused with a message when they do, and
it is rolled back when the plugin fails validation. The copies follow the same
rules:

  * Omarchy's plugin changed (an update), or OmacVM's patch did: the copy
    becomes Omarchy's plugin with the patch again (what OmacVM would make
    now), merged three ways with the copy as it is against what OmacVM wrote
    the last time (kept in ~/.local/state/omanotch/copies/NAME/written). Your
    own edits stay when they merge cleanly (git merge-file).
  * They overlap Omarchy's changes, the patch does not fit Omarchy's new file,
    or what the copy was made from is not known (a copy older than this, made
    from an older Omarchy): the copy stays as it is, and omacvm check and the
    control centre say so (the overlapping files, both sides marked, in
    .../copies/NAME/conflict). Tried again when Omarchy, the patch or the copy
    changes.
  * After a change the shell restarts and must load the copies without errors
    (and the bar answer on its notchbar IPC target); otherwise every changed
    file goes back as it was and the shell restarts again.

Lines that shell-colors.py (#376) changes in the copies and in Omarchy's own
files (a marked import) are OmacVM's, not yours: compared without them.
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
HOME = os.path.expanduser("~")
USER = os.environ.get("USER") or os.path.basename(HOME)
PLUGINS = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "omarchy/plugins")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "omanotch/copies")
RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
SHELL_COLORS = "/usr/local/lib/omacvm/shell-colors.py"
PACMAN_LOCK = "/var/lib/pacman/db.lck"
BACKUP = ".before-notchbar"
MARK = "omarchy-notch-bar"

# shell-colors.py's marked import (OmacVM's, #376): back to the plain import.
PINNED = re.compile(r"^import QtQuick \d+\.\d+ // omacvm #376: QtQuick's own Color \(Qt 6\.12\) would hide Omarchy's[ \t]*$", re.M)


class Copy:
    def __init__(self, name, source, entry, patcher, title, ipc):
        self.name, self.source, self.entry, self.title, self.ipc = name, source, entry, title, ipc
        self.patcher = os.path.join(HERE, patcher)
        self.dir = os.path.join(PLUGINS, f"{USER}.{name}")
        self.state = os.path.join(STATE, name)

    def state_file(self, *parts):
        return os.path.join(self.state, *parts)


COPIES = [
    Copy("bar", "omarchy.bar", "Bar.qml", "bar/apply-patch.py", "bar copy", ipc=True),
    Copy("background", "omarchy.background", "Background.qml", "background/apply-patch.py", "background copy", ipc=False),
]


class Stop(Exception):
    """The copy stays as it is: result (state.json), why, the files, and the
    sums it was tried with (tried again only when one of them changes)."""
    def __init__(self, result, why, files=(), tried=None):
        super().__init__(why)
        self.result, self.why, self.files, self.tried = result, why, list(files), tried


# ---- trees: relative path -> bytes ----

def normalize(rel, data):
    if data is not None and rel.endswith((".qml", BACKUP)):
        try:
            return PINNED.sub("import QtQuick", data.decode("utf-8")).encode("utf-8")
        except UnicodeDecodeError:
            return data
    return data


def read_tree(top):
    """Every file under top (links followed, as omarchy plugin clone copies
    them), normalized. Hidden files and folders and Omanotch's unpatched
    backups are not part of a plugin's files."""
    tree = {}
    for root, dirs, names in os.walk(top, followlinks=True):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for n in sorted(names):
            if n.startswith(".") or n.endswith((BACKUP, ".omacvm-tmp")):
                continue
            p = os.path.join(root, n)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rel = os.path.relpath(p, top)
            tree[rel] = normalize(rel, data)
    return tree


def tree_sum(tree):
    h = hashlib.sha256()
    for rel in sorted(tree):
        h.update(rel.encode() + b"\0" + hashlib.sha256(tree[rel]).digest())
    return h.hexdigest()[:16]


def file_sum(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]


def write_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".omacvm-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)


def write_tree(top, tree):
    if os.path.isdir(top):
        shutil.rmtree(top)
    for rel, data in tree.items():
        write_file(os.path.join(top, rel), data)


# ---- what OmacVM makes from Omarchy's plugin ----

def stock_dir(source):
    """Omarchy's own plugin folder (the one omarchy plugin clone copies)."""
    base = os.path.join(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy", "shell/plugins")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return None
    for n in names:
        try:
            with open(os.path.join(base, n, "manifest.json")) as f:
                if json.load(f).get("id") == source:
                    return os.path.join(base, n)
        except (OSError, ValueError, AttributeError):
            continue
    return None


def clone_manifest(data, source, new_id):
    """manifest.json as omarchy-plugin-clone writes it for the copy."""
    m = json.loads(data)
    name = "My " + str(m.get("name") or m.get("id") or source)
    m["id"], m["name"] = new_id, name
    if isinstance(m.get("barWidget"), dict):
        m["barWidget"]["displayName"] = name
    om = m.get("omarchy") if isinstance(m.get("omarchy"), dict) else {}
    om["clonedFrom"] = source
    om.pop("clonePaths", None)
    m["omarchy"] = om
    return m


def dump(obj):
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def patch_text(c, data):
    """The entry file with OmacVM's patch (the patcher on a scratch copy)."""
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, c.entry)
        with open(p, "wb") as f:
            f.write(data)
        r = subprocess.run([sys.executable, c.patcher, p], capture_output=True, text=True)
        if r.returncode != 0:
            last = (r.stderr.strip().splitlines() or ["the patch stopped"])[0]
            raise Stop("misfit", f"OmacVM's patch does not fit Omarchy's {c.entry} ({last})")
        with open(p, "rb") as f:
            return f.read()


def expected(c, stock):
    """The copy OmacVM makes from Omarchy's plugin (stock: its tree)."""
    if c.entry not in stock or "manifest.json" not in stock:
        raise Stop("misfit", f"Omarchy's {c.source} has no {c.entry} or manifest.json")
    tree = dict(stock)
    tree["manifest.json"] = dump(clone_manifest(stock["manifest.json"], c.source, f"{USER}.{c.name}"))
    tree[c.entry] = patch_text(c, stock[c.entry])
    return tree


def version_of(c, text):
    """The patch's version in the entry file: 0 = none."""
    m = re.search(rb"// omarchy-notch-bar (?:background )?patch v(\d+)", text or b"")
    return int(m.group(1)) if m else (0 if MARK.encode() not in (text or b"") else -1)


def current_version(c):
    with open(c.patcher) as f:
        return int(re.search(r"^VERSION = (\d+)$", f.read(), re.M).group(1))


# ---- the three-way merge ----

def same_manifest(a, b):
    try:
        return a is not None and b is not None and json.loads(a) == json.loads(b)
    except ValueError:
        return a == b


def merge_manifest(base, ours, theirs):
    """Key by key: each side's own changes; None when a key changed on both."""
    try:
        b, o, t = json.loads(base), json.loads(ours), json.loads(theirs)
    except ValueError:
        return None
    out = {}
    for k in list(o) + [k for k in t if k not in o]:
        bv, ov, tv = b.get(k, KeyError), o.get(k, KeyError), t.get(k, KeyError)
        v = tv if ov == bv else ov if tv == bv or ov == tv else None
        if v is None and not (ov == bv or tv == bv or ov == tv):
            return None
        if v is not KeyError:
            out[k] = v
    return dump(out)


def merge_file(c, rel, base, ours, theirs):
    """git merge-file: (merged, None) or (None, the file with both sides marked)."""
    try:
        texts = [x.decode("utf-8") for x in (ours, base, theirs)]
    except UnicodeDecodeError:
        return None, None
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for n, t in zip(("ours", "base", "theirs"), texts):
            p = os.path.join(d, n)
            with open(p, "w", encoding="utf-8") as f:
                f.write(t)
            paths.append(p)
        try:
            r = subprocess.run(["git", "merge-file", "-p", "-L", "your copy", "-L", "OmacVM's last",
                                "-L", "Omarchy's new with OmacVM's patch"] + paths, capture_output=True)
        except OSError:
            raise Stop("conflict", f"your edits in {rel} need git to merge, and it is not installed")
        if r.returncode == 0:
            return r.stdout, None
        if r.returncode > 0 and r.returncode < 128:
            return None, r.stdout
        raise Stop("conflict", f"git merge-file failed on {rel}: {r.stderr.decode(errors='replace').strip()}")


def merge(c, base, ours, theirs):
    """The copy's new files (None: removed), the files with your edits that
    stay, and the files that conflict (with both sides marked)."""
    out, edits, conflicts = {}, [], {}
    for rel in sorted(set(base) | set(ours) | set(theirs)):
        b, o, t = base.get(rel), ours.get(rel), theirs.get(rel)
        if rel == "manifest.json" and o is not None and t is not None:
            if same_manifest(o, t) or same_manifest(t, b):
                out[rel] = o
                if not same_manifest(o, t):
                    edits.append(rel)
                continue
            if same_manifest(o, b):
                out[rel] = t
                continue
            m = merge_manifest(b, o, t) if b is not None else None
            if m is None:
                conflicts[rel] = None
            else:
                out[rel], edits = m, edits + [rel]
            continue
        if o == t:
            out[rel] = o
        elif o == b:
            out[rel] = t
        elif t == b:
            out[rel] = o
        elif None in (b, o, t):
            conflicts[rel] = None   # removed on one side, changed on the other
            continue
        else:
            merged, marked = merge_file(c, rel, b, o, t)
            if merged is None:
                conflicts[rel] = marked
                continue
            out[rel] = merged
        if out[rel] != t:
            edits.append(rel)
    return {k: v for k, v in out.items() if v is not None}, edits, conflicts


# ---- state ----

def load_state(c):
    try:
        with open(c.state_file("state.json")) as f:
            s = json.load(f)
        return s if isinstance(s, dict) else None
    except (OSError, ValueError):
        return None


def save_state(c, s):
    os.makedirs(c.state, exist_ok=True)
    write_file(c.state_file("state.json"), dump(s))


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


# ---- applying a change, and taking it back ----

def apply(c, ours_raw, result, stock_entry):
    """Writes the changed files, each one's old bytes first into pending/."""
    pend = c.state_file("pending")
    if os.path.isdir(pend):
        shutil.rmtree(pend)
    os.makedirs(os.path.join(pend, "old"))
    journal = {"changed": [], "added": []}
    new = dict(result)
    new[c.entry + BACKUP] = stock_entry
    raw = dict(ours_raw)
    for rel in sorted(set(raw) | set(new)):
        o, n = raw.get(rel), new.get(rel)
        if n is not None and o is not None and normalize(rel, o) == n:
            continue
        if o is None and n is None:
            continue
        if o is not None:
            write_file(os.path.join(pend, "old", rel), o)
            journal["changed"].append(rel)
        else:
            journal["added"].append(rel)
    write_file(os.path.join(pend, "journal.json"), dump(journal))
    for rel in journal["changed"] + journal["added"]:
        p = os.path.join(c.dir, rel)
        if new.get(rel) is None:
            os.unlink(p)
        else:
            write_file(p, new[rel])
    prune_dirs(c.dir)
    return journal["changed"] + journal["added"]


def roll_back(c):
    """Puts back what apply() changed (also after a refresh that was cut short)."""
    pend = c.state_file("pending")
    try:
        with open(os.path.join(pend, "journal.json")) as f:
            j = json.load(f)
    except (OSError, ValueError):
        shutil.rmtree(pend, ignore_errors=True)
        return False
    for rel in j.get("added", []):
        try:
            os.unlink(os.path.join(c.dir, rel))
        except FileNotFoundError:
            pass
    for rel in j.get("changed", []):
        with open(os.path.join(pend, "old", rel), "rb") as f:
            write_file(os.path.join(c.dir, rel), f.read())
    prune_dirs(c.dir)
    shutil.rmtree(pend, ignore_errors=True)
    return True


def prune_dirs(top):
    for root, dirs, names in os.walk(top, topdown=False):
        if root != top and not dirs and not names:
            try:
                os.rmdir(root)
            except OSError:
                pass


def raw_tree(c):
    """The copy's files as they are on disk (the old bytes apply() keeps),
    plus the unpatched backup of its entry file."""
    tree = {}
    for root, dirs, names in os.walk(c.dir, followlinks=True):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), c.dir)
            if n.startswith(".") or n.endswith(".omacvm-tmp") or (n.endswith(BACKUP) and rel != c.entry + BACKUP):
                continue
            try:
                with open(os.path.join(root, n), "rb") as f:
                    tree[rel] = f.read()
            except OSError:
                pass
    return tree


# ---- the shell ----

def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def shell_up():
    return run(["omarchy-shell", "shell", "ping"], 10)[0] == 0


def session_locked():
    return run(["omarchy-shell", "lock", "isLocked"], 10)[1] == "true"


def bar_answers():
    """Omanotch's bar is the one loaded: it answers on its IPC target."""
    rc, out = run(["omarchy-shell", "notchbar", "state"], 10)
    try:
        return rc == 0 and isinstance(json.loads(out).get("bars"), list)
    except (ValueError, AttributeError):
        return False


def shell_logs():
    top = os.path.join(RUNTIME, "quickshell/by-id")
    try:
        return {os.path.join(top, d, "log.log") for d in os.listdir(top)}
    except OSError:
        return set()


# Errors a copy's QML raises while the shell loads it. Binding loops and other
# warnings are no refusal (Omarchy's own bar has some).
ERROR = re.compile(r"TypeError|ReferenceError|SyntaxError|is not a type|is not installed|is not defined|"
                   r"Cannot assign|Unable to assign|Cannot read property|unavailable|[Ff]ailed to load|not found|"
                   r"Expected token|Unexpected token|Non-existent attached object|Invalid property assignment|"
                   r"Property value set multiple times|No such file or directory|Error:|^\S+ \S+\s+ERROR")
ENTRY = re.compile(r"^\d{4}-\d\d-\d\d \d")


def log_entries(text):
    """The shell log's entries: a dated line with the lines under it."""
    out = []
    for line in text.splitlines():
        if ENTRY.match(line) or not out:
            out.append(line)
        else:
            out[-1] += "\n" + line
    return out


LATER = "later"


def restart_and_check(copies):
    """Restarts the shell. The copies that did not load -> why; None when the
    shell did not come back at all; LATER when it did not restart (the session
    got locked in the meantime: Omarchy refuses then)."""
    answered = any(c.ipc for c in copies) and bar_answers()
    before = shell_logs()
    t0 = time.time()
    run(["omarchy-restart-shell"], 90)
    while time.time() - t0 < 45 and not shell_up():
        time.sleep(1)
    if not shell_up():
        return None
    time.sleep(4)   # the plugins load after the shell answers
    text = ""
    logs = sorted((p for p in shell_logs() - before if os.path.exists(p)), key=os.path.getmtime)
    if not logs:
        return LATER   # still the shell from before: it never saw the new files
    for p in logs[-1:]:
        with open(p, errors="replace") as f:
            text = f.read()
    bad = {}
    for c in copies:
        where = f"/plugins/{os.path.basename(c.dir)}/"
        lines = [e for e in log_entries(text) if where in e and ERROR.search(e) and "Binding loop" not in e]
        if lines:
            bad[c.name] = " ".join(lines[0].split()[2:])[:200]
        elif c.ipc and answered:
            # Answered before: must answer again (a few tries: the bar loads last).
            if not any(bar_answers() or time.sleep(2) for _ in range(5)):
                bad[c.name] = "the bar did not load (no answer on its notchbar IPC target)"
    return bad


def recolor(c):
    """shell-colors.py's import in the copy's new files (Qt 6.12, #376)."""
    if os.path.exists(SHELL_COLORS):
        run([sys.executable, SHELL_COLORS, c.dir], 60)


# ---- one copy ----

def origin(c, stock, ours, before):
    """What OmacVM made of the plugin the copy came from, patched as the copy
    is now (None: not known). The copy came from Omarchy's plugin as it is
    now when its entry file before the patch is Omarchy's."""
    orig_entry = before if before is not None else ours.get(c.entry)
    if orig_entry is None or orig_entry != stock.get(c.entry):
        return None
    base = expected(c, stock)
    if version_of(c, ours.get(c.entry)) == 0:
        base[c.entry] = stock[c.entry]   # a copy without the patch yet (just cloned)
    return base


def plan(c, install):
    """What to do with one copy: None (nothing), a dict for apply(), or Stop."""
    s = load_state(c)
    if os.path.isdir(c.state_file("pending")):
        roll_back(c)   # a refresh that was cut short
    sd = stock_dir(c.source)
    if sd is None:
        raise Stop("misfit", f"Omarchy's {c.source} plugin is not installed")
    stock = read_tree(sd)
    stock_sum, patch_sum = tree_sum(stock), file_sum(c.patcher)
    if not os.path.isfile(os.path.join(c.dir, c.entry)):
        if not install:
            raise Stop("missing", f"{show(c.dir)} is gone: Omarchy's own {c.name} is in use (repair Omanotch to make it again)")
        out = run(["omarchy-plugin-clone", c.source], 60)[1]
        if not os.path.isfile(os.path.join(c.dir, c.entry)):
            raise Stop("missing", f"omarchy plugin clone {c.source} made no copy ({out[:120]})")
        s = None   # a new copy: anything kept was about another one
    if s and s.get("result") == "current" and (s.get("stock"), s.get("patch")) == (stock_sum, patch_sum):
        return None
    ours_raw = raw_tree(c)
    ours = read_tree(c.dir)
    before = normalize(c.entry + BACKUP, ours_raw.get(c.entry + BACKUP))
    tried = {"stock": stock_sum, "patch": patch_sum, "copy": tree_sum(ours)}
    if s and s.get("result") not in ("current", "missing") and s.get("tried") == tried:
        raise Stop(s["result"], s.get("why", ""), s.get("files", []), tried)
    try:
        theirs = expected(c, stock)
        replaced = None
        if s and os.path.isdir(c.state_file("written")):
            base = read_tree(c.state_file("written"))
        else:
            # No record yet: a copy from before this, or just cloned. An
            # older patch is replaced as install.sh always did (from the
            # unpatched backup); the copy before that goes to the state folder.
            v = version_of(c, ours.get(c.entry))
            if v not in (0, current_version(c)):
                if before is None or MARK.encode() in before:
                    raise Stop("unknown", f"its {c.entry} has an older patch and no clean {c.entry}{BACKUP}")
                replaced = ours_raw[c.entry]
                ours[c.entry] = patch_text(c, before)
            base = origin(c, stock, ours, before)
            if base is None:
                raise Stop("unknown", "it was made from an older Omarchy, so which of its changes are yours is not known")
        result, edits, conflicts = merge(c, base, ours, theirs)
        if conflicts:
            write_tree(c.state_file("conflict"), {rel: m for rel, m in conflicts.items() if m is not None})
            raise Stop("conflict", "your edits overlap Omarchy's changes in " + ", ".join(sorted(conflicts)), sorted(conflicts))
    except Stop as e:
        e.tried = tried
        raise
    if replaced is not None:
        write_file(c.state_file("replaced", c.entry), replaced)
    return {"result": result, "theirs": theirs, "edits": edits, "ours_raw": ours_raw,
            "stock_entry": stock[c.entry], "tried": tried, "replaced": replaced is not None,
            "changed": replaced is not None or tree_sum(result) != tree_sum(ours)
            or normalize(c.entry + BACKUP, ours_raw.get(c.entry + BACKUP)) != stock[c.entry]}


def commit(c, p, updated):
    write_tree(c.state_file("written"), p["theirs"])
    shutil.rmtree(c.state_file("pending"), ignore_errors=True)
    shutil.rmtree(c.state_file("conflict"), ignore_errors=True)
    old = load_state(c) or {}
    save_state(c, {"result": "current", "stock": p["tried"]["stock"], "patch": p["tried"]["patch"],
                   "edits": p["edits"], "updated": now() if updated else old.get("updated", "")})


def stopped(c, e):
    s = load_state(c) or {}
    s.update({"result": e.result, "why": e.why, "files": e.files, "tried": e.tried, "at": now()})
    save_state(c, s)


def show(path):
    return "~" + path[len(HOME):] if path.startswith(HOME + "/") else path


def follow(install=False):
    """Every copy; one line each. 0: done, 1: one was rolled back, 3: the
    session is locked (nothing done: the service does it after the unlock)."""
    if session_locked():
        print("copies: the session is locked: after the unlock")
        return 3
    todo, rc = [], 0
    for c in COPIES:
        if not install and load_state(c) is None and not os.path.isdir(c.dir):
            continue   # never set up here
        try:
            p = plan(c, install)
        except Stop as e:
            stopped(c, e)
            print(f"{c.title}: kept as it is: {e.why}")
            continue
        if p is None or not p["changed"]:
            if p is not None:
                commit(c, p, updated=False)
            print(f"{c.title}: up to date")
            continue
        apply(c, p["ours_raw"], p["result"], p["stock_entry"])
        recolor(c)
        todo.append((c, p))
    if not todo:
        return rc
    bad = restart_and_check([c for c, _ in todo])
    if bad == LATER:
        for c, _ in todo:
            roll_back(c)
        print("copies: the shell did not restart (the session is locked?): after the unlock")
        return 3
    for c, p in todo:
        why = "the shell did not come back after the restart" if bad is None else bad.get(c.name)
        if why:
            roll_back(c)
            stopped(c, Stop("rolled-back", f"Omarchy's {c.name} with OmacVM's patch did not load ({why}): back as it was",
                            tried=p["tried"]))
            print(f"{c.title}: rolled back: {why}")
            rc = 1
        else:
            commit(c, p, updated=True)
            kept = f" (your edits kept: {', '.join(p['edits'])})" if p["edits"] else ""
            replaced = f"; the copy before the patch's update: {show(c.state_file('replaced', c.entry))}" if p["replaced"] else ""
            print(f"{c.title}: follows Omarchy's {c.name}{kept}{replaced}")
    if rc:
        restart_and_check([])
    print("copies: the shell restarted")
    return rc


# ---- waiting for a quiet moment (the service) ----

def pacman_busy():
    if not os.path.exists(PACMAN_LOCK):
        return False
    # A lock left behind by a pacman that died is not an update.
    return run(["pgrep", "-x", "pacman"], 5)[0] == 0


def wait_quiet(limit=4 * 3600):
    """pacman done, no `omarchy update` running (its lock), the shell up and
    the session unlocked. False after limit seconds."""
    end = time.time() + limit
    lock = os.path.join(RUNTIME, "omarchy-update.lock")
    while time.time() < end:
        if pacman_busy():
            time.sleep(3)
            continue
        if os.path.exists(lock):
            try:
                with open(lock) as f:
                    fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except OSError:
                time.sleep(3)
                continue
        if not shell_up() or session_locked():
            time.sleep(5)
            continue
        return True
    return False


def needs_work():
    """Anything for follow() to do (a cheap look, before waiting)."""
    for c in COPIES:
        s = load_state(c)
        if s is None:
            if os.path.isdir(c.dir):
                return True
            continue
        if os.path.isdir(c.state_file("pending")):
            return True
        sd = stock_dir(c.source)
        if sd is None or not os.path.isdir(c.dir):
            continue
        sums = (tree_sum(read_tree(sd)), file_sum(c.patcher))
        if s.get("result") == "current":
            if (s.get("stock"), s.get("patch")) != sums:
                return True
        else:
            t = s.get("tried") or {}
            if (t.get("stock"), t.get("patch"), t.get("copy")) != sums + (tree_sum(read_tree(c.dir)),):
                return True
    return False


# ---- omacvm check ----

def check_lines():
    """(ok|warn, name, detail) for each copy Omanotch keeps."""
    out = []
    for c in COPIES:
        s = load_state(c)
        if s is None:
            if os.path.isdir(c.dir):
                out.append(("ok", c.title, "Omanotch's patch on Omarchy's; follows Omarchy's updates from the next login"))
            continue
        res = s.get("result")
        if res == "current":
            sd = stock_dir(c.source)
            if sd and (tree_sum(read_tree(sd)), file_sum(c.patcher)) != (s.get("stock"), s.get("patch")):
                out.append(("ok", c.title, f"Omarchy's {c.name} changed: the copy follows when the session is unlocked, or at the next login"))
                continue
            d = "follows Omarchy's updates" + (f" (last {s['updated']})" if s.get("updated") else "")
            if s.get("edits"):
                d += f"; your edits kept: {', '.join(s['edits'])}"
            out.append(("ok", c.title, d))
        elif res == "conflict":
            out.append(("warn", c.title, f"not updated, kept as it is: {s.get('why')} (both sides marked in {show(c.state_file('conflict'))})"))
        elif res == "unknown":
            out.append(("warn", c.title, f"not updated, kept as it is: {s.get('why')} (to start from Omarchy's newest: move {show(c.dir)} away, then repair Omanotch)"))
        elif res == "missing" and os.path.isdir(c.dir):
            out.append(("ok", c.title, "back: follows Omarchy's updates from the next login"))
        else:
            out.append(("warn", c.title, f"not updated: {s.get('why')}"))
    return out


def main(argv):
    if argv[:1] == ["--check"]:
        for st, name, d in check_lines():
            print(f"{st}\t{name}\t{d}")
        return 0
    # One at a time (install.sh, the service).
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, ".lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    if "--wait" not in argv:
        return follow(install="--install" in argv)
    if not needs_work():
        print("copies: up to date")
        return 0
    for _ in range(3):
        if not wait_quiet():
            break
        rc = follow()
        if rc != 3:
            return rc
    print("copies: no quiet moment (an update or the lock screen): at the next login")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
