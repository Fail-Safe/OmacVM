#!/usr/bin/env python3
"""Omanotch's copies of Omarchy's bar and background follow Omarchy's updates
(guest/copies.py), offline: Omarchy's plugins are folders made from
src/tests/omarchy-shell (omarchy-mac's shell and upstream's newer one), the
shell's restart is a stand-in.

    python3 src/omanotch/guest/tests/test_copies.py
"""
import difflib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
GUEST = ROOT / "src/omanotch/guest"
SHELLS = ROOT / "src/tests/omarchy-shell"
MAC, UPSTREAM = "omarchy-mac-ba546a61", "omarchy-a06ec133"
USER = "tester"
PIN = "import QtQuick 6.11 // omacvm #376: QtQuick's own Color (Qt 6.12) would hide Omarchy's"

MANIFESTS = {
    "bar": {"schemaVersion": 1, "id": "omarchy.bar", "name": "Bar", "version": "1.0.0", "author": "Omarchy",
            "description": "Status bar with widgets", "kinds": ["bar"], "entryPoints": {"bar": "Bar.qml"}},
    "background": {"schemaVersion": 1, "id": "omarchy.background", "name": "Background", "version": "1.0.0",
                   "author": "Omarchy", "description": "Desktop background renderer", "kinds": ["service"],
                   "entryPoints": {"service": "Background.qml"}},
}


class Copies(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.omarchy = self.tmp / "omarchy"
        (self.home / ".config/omarchy/plugins").mkdir(parents=True)
        self.env = dict(os.environ)
        os.environ.update(HOME=str(self.home), USER=USER, OMARCHY_PATH=str(self.omarchy),
                          XDG_CONFIG_HOME=str(self.home / ".config"), XDG_STATE_HOME=str(self.home / ".local/state"),
                          XDG_RUNTIME_DIR=str(self.tmp / "run"))
        # copies.py with its patchers, as installed (~/.local/lib/omanotch).
        self.lib = self.tmp / "lib"
        for f in ("copies.py", "bar/apply-patch.py", "background/apply-patch.py"):
            (self.lib / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(GUEST / f, self.lib / f)
        self.load()
        self.restarts = 0
        self.refuse = {}     # what the stand-in shell refuses to load: copy name -> error
        self.locked = False
        self.shell("bar", MAC)
        self.shell("background", MAC)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.tmp)

    def load(self):
        spec = importlib.util.spec_from_file_location("copies", self.lib / "copies.py")
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        m = self.m

        def restart(copies):
            self.restarts += 1
            return {c.name: self.refuse[c.name] for c in copies if c.name in self.refuse}

        def run(cmd, timeout=30):
            if cmd[:1] == ["omarchy-plugin-clone"]:
                return self.clone(cmd[1]), ""
            return 1, ""
        m.print = lambda *a, **k: None   # its one line per copy
        m.restart_and_check = restart
        m.session_locked = lambda: self.locked
        m.recolor = lambda c: None
        m.run = run

    # ---- Omarchy's side ----
    def shell(self, name, which, change=None):
        """Omarchy's plugin `name` as in that shell (an update replaces it)."""
        d = self.omarchy / "shell/plugins" / name
        if d.exists():
            shutil.rmtree(d)
        shutil.copytree(SHELLS / which / "shell/plugins" / name, d)
        (d / "manifest.json").write_text(json.dumps(MANIFESTS[name], indent=2) + "\n")
        (d / "README.md").write_text(f"Omarchy's {name} ({which})\n")
        if change:
            change(d)

    def clone(self, source):
        """omarchy plugin clone: the folder, and jq's manifest."""
        name = source.split(".", 1)[1]
        target = self.plugins / f"{USER}.{name}"
        shutil.copytree(self.omarchy / "shell/plugins" / name, target)
        m = json.loads((target / "manifest.json").read_text())
        m.update(id=f"{USER}.{name}", name=f"My {m['name']}", omarchy={"clonedFrom": source})
        (target / "manifest.json").write_text(json.dumps(m, indent=2, separators=(",", ": ")) + "\n")
        return 0

    @property
    def plugins(self):
        return self.home / ".config/omarchy/plugins"

    def copy(self, name="bar"):
        return self.plugins / f"{USER}.{name}"

    def entry(self, name="bar"):
        return self.copy(name) / ("Bar.qml" if name == "bar" else "Background.qml")

    def files(self, top):
        return {str(p.relative_to(top)): p.read_bytes() for p in sorted(top.rglob("*")) if p.is_file()}

    def follow(self, install=False):
        return self.m.follow(install=install)

    def state(self, name="bar"):
        return json.loads((self.home / ".local/state/omanotch/copies" / name / "state.json").read_text())

    def check(self):
        return {name: (st, d) for st, name, d in self.m.check_lines()}

    def patched(self, name, which):
        c = next(c for c in self.m.COPIES if c.name == name)
        entry = SHELLS / which / "shell/plugins" / name / c.entry
        return self.m.patch_text(c, entry.read_bytes())

    # ---- edits ----
    def quiet_line(self, a, b):
        """A line in the middle of a long stretch both texts share."""
        al, bl = a.decode().splitlines(True), b.decode().splitlines(True)
        best = max((blk for blk in difflib.SequenceMatcher(None, al, bl, autojunk=False).get_matching_blocks()),
                   key=lambda blk: blk.size)
        self.assertGreater(best.size, 20)
        mid = best.a + best.size // 2
        # One that is there once (the edit finds it), away from the block's ends.
        return next(al[i] for i in sorted(range(best.a + 5, best.a + best.size - 5), key=lambda i: abs(i - mid))
                    if al.count(al[i]) == 1 and al[i].strip())

    def changed_line(self, a, b):
        """A line of a that b changes."""
        al, bl = a.decode().splitlines(True), b.decode().splitlines(True)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, al, bl, autojunk=False).get_opcodes():
            if tag == "replace" and al[i1].strip():
                return al[i1]
        self.fail("no changed line")

    def edit(self, path, old, new):
        text = path.read_text()
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new))

    # ---- tests ----
    def test_install_makes_and_patches_both_copies(self):
        for which in (MAC, UPSTREAM):
            with self.subTest(which):
                for name in ("bar", "background"):
                    if self.copy(name).exists():
                        shutil.rmtree(self.copy(name))
                    self.shell(name, which)
                shutil.rmtree(self.home / ".local/state", ignore_errors=True)
                self.assertEqual(self.follow(install=True), 0)
                for name in ("bar", "background"):
                    self.assertEqual(self.entry(name).read_bytes(), self.patched(name, which))
                    backup = self.entry(name).with_name(self.entry(name).name + ".before-notchbar")
                    self.assertEqual(backup.read_bytes(), (SHELLS / which / "shell/plugins" / name / self.entry(name).name).read_bytes())
                    self.assertEqual(self.state(name)["result"], "current")
                    self.assertEqual(self.check()[f"{name} copy"][0], "ok")
                n = self.restarts
                self.assertEqual(self.follow(), 0)
                self.assertEqual(self.restarts, n, "nothing changed: no restart")

    def test_unchanged_copy_follows_an_update(self):
        for old, new in ((MAC, UPSTREAM), (UPSTREAM, MAC)):
            with self.subTest(f"{old} -> {new}"):
                self.reset(old)
                self.follow(install=True)
                n = self.restarts
                self.shell("bar", new)
                self.shell("background", new)
                self.assertEqual(self.follow(), 0)
                self.assertEqual(self.restarts, n + 1, "one restart for both copies")
                for name in ("bar", "background"):
                    self.assertEqual(self.entry(name).read_bytes(), self.patched(name, new))
                    self.assertEqual(self.state(name)["edits"], [])
                self.assertEqual((self.copy() / "widgets/Indicators.qml").read_bytes(),
                                 (SHELLS / new / "shell/plugins/bar/widgets/Indicators.qml").read_bytes())
                self.assertEqual((self.copy() / "README.md").read_text(), f"Omarchy's bar ({new})\n")
                self.assertEqual(json.loads((self.copy() / "manifest.json").read_text())["id"], f"{USER}.bar")

    def reset(self, which):
        for name in ("bar", "background"):
            if self.copy(name).exists():
                shutil.rmtree(self.copy(name))
            self.shell(name, which)
        shutil.rmtree(self.home / ".local/state", ignore_errors=True)

    def test_your_edits_stay_when_they_merge(self):
        self.follow(install=True)
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), mine, mine + "  // mine: stays\n")
        widget = self.copy() / "widgets/Mine.qml"
        widget.write_text("Item {}\n")
        readme = self.copy() / "README.md"
        readme.write_text(readme.read_text() + "my notes\n")   # Omarchy's update leaves it as it was
        self.shell("bar", UPSTREAM, change=lambda d: (d / "README.md").write_text("Omarchy's bar (mac)\n".replace("(mac)", f"({MAC})")))
        self.assertEqual(self.follow(), 0)
        text = self.entry().read_text()
        self.assertIn("// mine: stays", text)
        # Everything else is Omarchy's new bar with the patch.
        self.assertEqual(text.replace(mine + "  // mine: stays\n", mine), self.patched("bar", UPSTREAM).decode())
        self.assertEqual(widget.read_text(), "Item {}\n")
        self.assertEqual(readme.read_text(), f"Omarchy's bar ({MAC})\nmy notes\n")
        self.assertEqual(sorted(self.state()["edits"]), ["Bar.qml", "README.md", "widgets/Mine.qml"])
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "ok")
        self.assertIn("your edits kept: Bar.qml", d)
        # The next update merges against what OmacVM wrote this time.
        self.shell("bar", MAC)
        self.assertEqual(self.follow(), 0)
        self.assertIn("// mine: stays", self.entry().read_text())

    def test_overlapping_edit_keeps_the_copy_and_says_so(self):
        self.follow(install=True)
        line = self.changed_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), line, line.rstrip("\n") + " // mine\n")
        before = self.files(self.copy())
        n = self.restarts
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before, "the copy stays exactly as it was")
        self.assertEqual(self.restarts, n)
        s = self.state()
        self.assertEqual((s["result"], s["files"]), ("conflict", ["Bar.qml"]))
        marked = (self.home / ".local/state/omanotch/copies/bar/conflict/Bar.qml").read_text()
        self.assertIn("<<<<<<< your copy", marked)
        self.assertIn(">>>>>>> Omarchy's new with OmacVM's patch", marked)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("your edits overlap Omarchy's changes in Bar.qml", d)
        # Not tried again until something changes; the background followed.
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before)
        self.assertFalse(self.m.needs_work())
        # Your copy taking Omarchy's change too: it merges.
        self.entry().write_text(self.entry().read_text().replace(line.rstrip("\n") + " // mine\n", line))
        self.assertTrue(self.m.needs_work())
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.state()["result"], "current")
        self.assertFalse((self.home / ".local/state/omanotch/copies/bar/conflict").exists())

    def test_a_copy_that_does_not_load_goes_back(self):
        self.follow(install=True)
        before = {n: self.files(self.copy(n)) for n in ("bar", "background")}
        self.shell("bar", UPSTREAM)
        self.shell("background", UPSTREAM)
        self.refuse = {"bar": "Bar.qml:120: TypeError: Cannot read property 'x' of undefined"}
        n = self.restarts
        self.assertEqual(self.follow(), 1)
        self.assertEqual(self.restarts, n + 2, "a restart to try, one to go back")
        self.assertEqual(self.files(self.copy("bar")), before["bar"], "every file as it was")
        self.assertNotEqual(self.files(self.copy("background")), before["background"], "the background loaded: it stays")
        self.assertEqual(self.state("bar")["result"], "rolled-back")
        self.assertFalse((self.home / ".local/state/omanotch/copies/bar/pending").exists())
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("did not load", d)
        # Not again for the same update...
        self.refuse = {}
        n = self.restarts
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.restarts, n)
        # ... but for the next one.
        self.shell("bar", UPSTREAM, change=lambda d: (d / "README.md").write_text("next\n"))
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_a_refresh_cut_short_is_taken_back(self):
        self.follow(install=True)
        before = self.files(self.copy())
        self.shell("bar", UPSTREAM)
        c = self.m.COPIES[0]
        p = self.m.plan(c, False)
        self.m.apply(c, p["ours_raw"], p["result"], p["stock_entry"])   # then the VM went off
        self.assertNotEqual(self.files(self.copy()), before)
        self.assertTrue(self.m.needs_work())
        self.refuse = {"bar": "TypeError"}
        self.assertEqual(self.follow(), 1)
        self.assertEqual(self.files(self.copy()), before)

    def test_shell_colors_lines_are_not_your_edits(self):
        self.follow(install=True)
        for p in [self.entry(), self.entry().with_name("Bar.qml.before-notchbar"), self.copy() / "widgets/Indicators.qml"]:
            p.write_text(re.sub(r"(?m)^import QtQuick$", PIN, p.read_text()))
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.state()["edits"], [])
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_your_manifest_name_stays(self):
        self.follow(install=True)
        m = json.loads((self.copy() / "manifest.json").read_text())
        m["name"] = "Gilles' bar"
        (self.copy() / "manifest.json").write_text(json.dumps(m, indent=4))
        MANIFESTS["bar"]["version"] = "1.1.0"
        try:
            self.shell("bar", UPSTREAM)
        finally:
            MANIFESTS["bar"]["version"] = "1.0.0"
        self.assertEqual(self.follow(), 0)
        m = json.loads((self.copy() / "manifest.json").read_text())
        self.assertEqual((m["name"], m["version"], m["id"]), ("Gilles' bar", "1.1.0", f"{USER}.bar"))

    def test_a_new_patch_keeps_your_edits(self):
        self.follow(install=True)
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", MAC))
        self.edit(self.entry(), mine, mine + "  // mine\n")
        self.newer_patch()
        self.assertEqual(self.follow(), 0)
        text = self.entry().read_text()
        self.assertIn("  // mine\n", text)
        self.assertIn("// newer patch", text)

    def newer_patch(self):
        """OmacVM's patch changes: the bar patcher adds a line."""
        src = (self.lib / "bar/apply-patch.py").read_text()
        src = src.replace('    open(path, "w").write(text)\n    print("patched")',
                          '    text = text.replace(VERSION_LINE, VERSION_LINE + "\\n  // newer patch", 1)\n'
                          '    open(path, "w").write(text)\n    print("patched")')
        self.assertIn("// newer patch", src)
        (self.lib / "bar/apply-patch.py").write_text(src)

    def test_a_copy_from_before_this_is_taken_over(self):
        # As install.sh made it before: clone, backup, patch in place.
        self.clone("omarchy.bar")
        shutil.copy(self.entry(), self.entry().with_name("Bar.qml.before-notchbar"))
        self.entry().write_bytes(self.patched("bar", MAC))
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), mine, mine + "  // mine\n")
        self.assertEqual(self.check()["bar copy"][0], "ok")
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.state()["result"], "current")
        self.assertEqual(self.state()["edits"], ["Bar.qml"])
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertIn("  // mine\n", self.entry().read_text())
        self.assertEqual(self.entry().read_text().replace(mine + "  // mine\n", mine), self.patched("bar", UPSTREAM).decode())

    def test_an_older_patch_is_replaced_and_kept(self):
        self.clone("omarchy.bar")
        shutil.copy(self.entry(), self.entry().with_name("Bar.qml.before-notchbar"))
        v = self.m.current_version(self.m.COPIES[0])
        old = self.patched("bar", MAC).replace(b"patch v%d" % v, b"patch v%d" % (v - 1))
        self.entry().write_bytes(old)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", MAC))
        self.assertEqual((self.home / ".local/state/omanotch/copies/bar/replaced/Bar.qml").read_bytes(), old)

    def test_a_copy_of_an_older_omarchy_is_left_alone(self):
        # Made from omarchy-mac's bar, Omarchy now upstream's, no record.
        self.clone("omarchy.bar")
        shutil.copy(self.entry(), self.entry().with_name("Bar.qml.before-notchbar"))
        self.entry().write_bytes(self.patched("bar", MAC))
        self.shell("bar", UPSTREAM)
        before = self.files(self.copy())
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("made from an older Omarchy", d)
        self.assertIn("move ~/.config/omarchy/plugins/tester.bar away, then repair Omanotch", d)
        # Moved away and repaired: a new copy of Omarchy's newest.
        shutil.rmtree(self.copy())
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))
        self.assertEqual(self.check()["bar copy"][0], "ok")

    def test_a_patch_that_does_not_fit_keeps_the_copy(self):
        self.follow(install=True)
        before = self.files(self.copy())
        self.shell("bar", UPSTREAM, change=lambda d: (d / "Bar.qml").write_text(
            (d / "Bar.qml").read_text().replace('  property string home: Quickshell.env("HOME")\n', "")))
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("OmacVM's patch does not fit", d)

    def test_locked_session_waits(self):
        self.follow(install=True)
        self.shell("bar", UPSTREAM)
        self.locked = True
        before = self.files(self.copy())
        self.assertEqual(self.follow(), 3)
        self.assertEqual(self.files(self.copy()), before)
        self.assertTrue(self.m.needs_work())
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "ok")
        self.assertIn("follows when the session is unlocked", d)

    def test_a_removed_copy(self):
        self.follow(install=True)
        shutil.rmtree(self.copy())
        self.assertEqual(self.follow(), 0)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("is gone", d)
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.check()["bar copy"][0], "ok")


if __name__ == "__main__":
    unittest.main(verbosity=1)
