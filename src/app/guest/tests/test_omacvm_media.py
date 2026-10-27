#!/usr/bin/env python3
"""Tests for omacvm-media, the VM's side of AirPods and media controls.

    python3 src/app/guest/tests/test_omacvm_media.py

The rules (which player, what a state line holds, caps, the port's hello) run
anywhere. With python-gobject and dbus-daemon (Linux, the guest CI job) the
agent also runs against fake MPRIS players on a private session bus, with a
socket pair as the port and this test as the Mac.
"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
AGENT = HERE.parent / "omacvm-media"
loader = importlib.machinery.SourceFileLoader("omacvm_media", str(AGENT))
spec = importlib.util.spec_from_loader("omacvm_media", loader)
om = importlib.util.module_from_spec(spec)
loader.exec_module(om)

try:
    import gi  # noqa: F401
    gi.require_version("Gio", "2.0")
    HAVE_GI = True
except (ImportError, ValueError):
    HAVE_GI = False
HAVE_DBUS = HAVE_GI and shutil.which("dbus-daemon") is not None


def player(name="org.mpris.MediaPlayer2.mpv", status="Stopped", **props):
    p = om.Player(name)
    p.status = status
    p.update(props, 0.0)
    return p


class Clean(unittest.TestCase):
    def test_caps_and_hidden(self):
        self.assertEqual(om.clean("a" * 500, 200), "a" * 200)
        self.assertEqual(om.clean("a\x00b\x1bc\x7fd\x85e\nf\tg", 200), "abcdefg")
        self.assertEqual(om.clean("x\u202eevil\u202c\u2066y\u2069\u200f\u061cz\u2028", 200), "xevilyz")
        self.assertEqual(om.clean(5, 200), "")
        self.assertEqual(om.clean(None, 200), "")
        self.assertEqual(om.clean("  padded ", 200), "padded")

    def test_cut_before_hidden_characters_count(self):
        self.assertEqual(om.clean("\u202e" * 10 + "abc", 2), "ab")


class StateLine(unittest.TestCase):
    def test_fields(self):
        p = player(status="Playing", Metadata={"xesam:title": "Song", "xesam:artist": ["A", "B"], "xesam:album": "LP",
                                               "mpris:length": 213_500_000},
                   Rate=1.0, CanGoNext=True, CanGoPrevious=False)
        p.identity = "mpv Media Player"
        p.position = 12_000_000
        self.assertEqual(om.state_message(p), {
            "t": "state", "s": "playing", "player": "mpv Media Player", "title": "Song", "artist": "A, B",
            "album": "LP", "rate": 1.0, "next": True, "prev": False, "len": 213.5, "pos": 12.0})

    def test_status_words(self):
        for mpris, word in (("Playing", "playing"), ("Paused", "paused"), ("Stopped", "stopped"), ("Odd", "stopped")):
            self.assertEqual(om.state_message(player(status=mpris))["s"], word)
        self.assertEqual(om.state_message(None), {"t": "state", "s": "none"})

    def test_odd_metadata(self):
        p = player(status="Playing", Metadata={"xesam:title": 5, "xesam:artist": "Solo", "mpris:length": True})
        m = om.state_message(p)
        self.assertEqual((m["title"], m["artist"]), ("", "Solo"))
        self.assertNotIn("len", m)
        self.assertEqual(m["player"], "mpv", "no Identity: the bus name")
        p.rate = 99
        self.assertEqual(om.state_message(p)["rate"], 1.0)

    def test_biggest_line_fits_4_kb(self):
        # The Mac drops lines over 4 KB (app/app/Sources/OmacVMMedia): the fields are cut
        # first and the line is UTF-8, so 200 emoji per field still fit; escaped
        # (json's default) they would not.
        e = "\U0001F600" * 500
        p = player(status="Playing", Metadata={"xesam:title": e, "xesam:artist": [e], "xesam:album": e,
                                               "mpris:length": 86_399_999_999})
        p.identity = e
        p.position = 86_399_999_999
        line = om.encode(om.state_message(p))
        self.assertLessEqual(len(line), om.MAX_LINE)
        self.assertIn("\U0001F600".encode(), line)
        self.assertGreater(len(json.dumps(om.state_message(p)).encode()), om.MAX_LINE)


class Pick(unittest.TestCase):
    def test_rules(self):
        a, b, c = player("org.mpris.MediaPlayer2.a"), player("org.mpris.MediaPlayer2.b"), player("org.mpris.MediaPlayer2.c")
        self.assertIsNone(om.pick([a, b, c]), "nothing played, nothing paused: none")
        c.update({"PlaybackStatus": "Paused"}, 1.0)
        self.assertIs(om.pick([a, b, c]), c, "at start, a paused one")
        a.update({"PlaybackStatus": "Playing"}, 2.0)
        b.update({"PlaybackStatus": "Playing"}, 3.0)
        self.assertIs(om.pick([a, b, c]), b, "the one that went into Playing last")
        b.update({"PlaybackStatus": "Paused"}, 4.0)
        self.assertIs(om.pick([a, b, c]), a, "the other still plays")
        a.update({"PlaybackStatus": "Paused"}, 5.0)
        self.assertIs(om.pick([a, b, c]), a, "none playing: the one that played last")
        b.update({"PlaybackStatus": "Playing"}, 6.0)
        b.update({"Metadata": {"xesam:title": "next"}}, 7.0)
        self.assertIs(om.pick([a, b, c]), b)
        self.assertEqual(b.since, 6.0, "a new title does not move when it went into Playing")


class Port(unittest.TestCase):
    """The agent's port, without GLib: a socket pair, this test as the Mac."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.mac, guest = socket.socketpair()
        self.agent = om.Agent(guest.detach(), status=pathlib.Path(self.tmp) / "media")
        self.mac.setblocking(False)

    def tearDown(self):
        self.mac.close()
        os.close(self.agent.fd)
        shutil.rmtree(self.tmp)

    def lines(self):
        out = b""
        while True:
            try:
                d = self.mac.recv(65536)
            except BlockingIOError:
                break
            if not d:
                break
            out += d
        return [json.loads(x) for x in out.split(b"\n") if x]

    def status(self):
        return json.loads((pathlib.Path(self.tmp) / "media").read_text())

    def test_hello_and_answers(self):
        self.agent.due_hello()
        hello = self.lines()
        self.assertEqual(len(hello), 1)
        self.assertEqual((hello[0]["t"], hello[0]["v"], hello[0]["n"]), ("hello", 1, self.agent.id))
        self.assertEqual(self.status()["mac"], "silent")
        # Left in the port from before this run: an old answer and a command.
        self.agent.take(b'{"t":"hello","v":1,"on":true,"n":"old"}\n{"t":"cmd","c":"play"}\n')
        self.assertFalse(self.agent.accepted or self.agent.on, "an earlier run's answer does not count")
        self.agent.take(json.dumps({"t": "hello", "v": 1, "on": False, "n": self.agent.id}).encode() + b"\n")
        self.assertTrue(self.agent.accepted)
        self.assertFalse(self.agent.on)
        self.assertEqual(self.status()["mac"], "off")
        self.assertIsNone(self.agent.glib, "off: python-gobject not even loaded")
        self.assertNotIn("hello", self.agent.due, "answered: no more hellos")

    def test_hello_without_n_asks_again(self):
        self.agent.accepted = True
        self.agent.take(b'{"t":"hello","v":1,"on":true}\n')
        self.assertFalse(self.agent.accepted)
        self.assertIn("hello", self.agent.due)

    def test_garbage_and_long_lines(self):
        self.agent.take(b"not json\n[1]\n" + b"x" * 5000 + b'\n{"t":"cmd","c":"play"}\n')
        self.assertFalse(self.agent.accepted)
        self.agent.take(b"y" * 5000)
        self.assertEqual(self.agent.buffer, b"", "a line over 4 KB is dropped up to its newline")
        self.assertTrue(self.agent.skipping)

    def test_mac_not_connected(self):
        self.mac.close()
        self.agent.readable()
        self.assertFalse(self.agent.reachable)
        self.assertIn("retry", self.agent.due, "tries again later instead of reading EOF in a loop")
        self.mac = socket.socket()

    def test_only_the_latest_state_waits(self):
        self.agent.watching = self.agent.accepted = self.agent.on = True
        self.agent.reachable = True
        full = b"z" * 300000   # the peer's buffer full
        try:
            while True:
                os.write(self.agent.fd, full)
        except BlockingIOError:
            pass
        p = player(status="Playing", Metadata={"xesam:title": "one"})
        self.agent.send(p)
        p.update({"Metadata": {"xesam:title": "two"}}, 1.0)
        self.agent.send(p)
        self.assertIn(b'"two"', self.agent.state_out or self.agent.partial)
        self.assertNotIn(b'"one"', (self.agent.state_out or b"") + self.agent.partial)

    def test_titles_never_in_the_status_file(self):
        self.agent.watching = self.agent.accepted = self.agent.on = True
        p = player(status="Playing", Metadata={"xesam:title": "SECRET Song", "xesam:artist": "SECRET Band"})
        p.identity = "Chromium"
        self.agent.send(p)
        sent = self.lines()
        self.assertEqual(sent[-1]["title"], "SECRET Song", "the title goes to the Mac")
        text = (pathlib.Path(self.tmp) / "media").read_text()
        self.assertNotIn("SECRET", text)
        self.assertEqual((self.status()["player"], self.status()["state"]), ("Chromium", "playing"))

    def test_never_a_toggle(self):
        self.assertEqual(set(om.METHODS.values()), {"Play", "Pause", "Next", "Previous"})
        self.agent.take(b'{"t":"cmd","c":"PlayPause"}\n{"t":"cmd","c":"toggle"}\n')
        self.assertEqual(self.agent.status["command"], "")


FAKE = r'''
import sys
from gi.repository import Gio, GLib
name, identity = sys.argv[2], sys.argv[3]
XML = """<node>
<interface name="org.mpris.MediaPlayer2"><property name="Identity" type="s" access="read"/></interface>
<interface name="org.mpris.MediaPlayer2.Player">
 <method name="Play"/><method name="Pause"/><method name="PlayPause"/><method name="Next"/>
 <method name="Previous"/><method name="Stop"/>
 <property name="PlaybackStatus" type="s" access="read"/><property name="Metadata" type="a{sv}" access="read"/>
 <property name="Rate" type="d" access="read"/><property name="Position" type="x" access="read"/>
 <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
</interface></node>"""
state = {"status": "Stopped", "title": "", "n": 0}
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
node = Gio.DBusNodeInfo.new_for_xml(XML)
def meta():
    return GLib.Variant("a{sv}", {"xesam:title": GLib.Variant("s", state["title"]),
                                  "xesam:artist": GLib.Variant("as", ["Fake Band"]),
                                  "mpris:length": GLib.Variant("x", 60000000),
                                  "mpris:trackid": GLib.Variant("o", "/fake/%d" % state["n"])})
def get(conn, sender, path, iface, prop):
    return {"Identity": GLib.Variant("s", identity), "PlaybackStatus": GLib.Variant("s", state["status"]),
            "Metadata": meta(), "Rate": GLib.Variant("d", 1.0), "Position": GLib.Variant("x", 5000000),
            "CanGoNext": GLib.Variant("b", True), "CanGoPrevious": GLib.Variant("b", False)}[prop]
def changed(**v):
    bus.emit_signal(None, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player", v, [])))
def set_status(s):
    state["status"] = s
    changed(PlaybackStatus=GLib.Variant("s", s))
def call(conn, sender, path, iface, method, params, inv):
    print("call " + method, flush=True)
    if method == "Play": set_status("Playing")
    elif method == "Pause": set_status("Paused")
    elif method == "Next":
        state["n"] += 1
        changed(Metadata=meta())
    inv.return_value(None)
for i in node.interfaces:
    bus.register_object("/org/mpris/MediaPlayer2", i, call, get, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
              GLib.Variant("(su)", (name, 4)), None, Gio.DBusCallFlags.NONE, 2000, None)
print("ready", flush=True)
def line(fd, cond):
    l = sys.stdin.readline().split(" ", 1)
    w = l[0].strip()
    if w in ("", "quit"):
        loop.quit(); return False
    if w == "play": set_status("Playing")
    elif w == "pause": set_status("Paused")
    elif w == "title":
        state["title"] = l[1].strip(); changed(Metadata=meta())
    return True
GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, 0, GLib.IOCondition.IN | GLib.IOCondition.HUP, line)
loop = GLib.MainLoop()
loop.run()
'''


@unittest.skipUnless(HAVE_DBUS, "needs python-gobject and dbus-daemon (Linux, the guest CI job)")
class WithPlayers(unittest.TestCase):
    """The agent on a private session bus with fake MPRIS players."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                                    stdout=subprocess.PIPE, text=True)
        self.env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=self.bus.stdout.readline().strip(),
                        XDG_RUNTIME_DIR=self.tmp)
        self.fake = pathlib.Path(self.tmp) / "fake.py"
        self.fake.write_text(FAKE)
        self.players = {}
        self.mac, guest = socket.socketpair()
        self.agent = subprocess.Popen([sys.executable, str(AGENT)], env=dict(self.env, OMACVM_MEDIA_FD=str(guest.fileno())),
                                      pass_fds=[guest.fileno()], stderr=subprocess.PIPE, text=True)
        guest.close()
        self.got = b""

    def tearDown(self):
        for p in self.players.values():
            p.kill()
            p.wait()
        self.agent.kill()
        self.agent.wait()
        self.stderr = self.agent.stderr.read()
        self.agent.stderr.close()
        self.bus.kill()
        self.bus.wait()
        self.bus.stdout.close()
        self.mac.close()
        shutil.rmtree(self.tmp)

    def start(self, key, identity):
        p = subprocess.Popen([sys.executable, str(self.fake), "-", "org.mpris.MediaPlayer2." + key, identity],
                             env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.assertEqual(p.stdout.readline().strip(), "ready")
        self.players[key] = p
        return p

    def tell(self, key, line):
        self.players[key].stdin.write(line + "\n")
        self.players[key].stdin.flush()

    def calls(self, key, wait=3.0):
        out = self.players[key].stdout
        r, _, _ = select.select([out], [], [], wait)
        return out.readline().strip() if r else ""

    def line(self, want=None, wait=5.0):
        """The agent's next line (with want: the next with that t and s)."""
        end = time.monotonic() + wait
        while time.monotonic() < end:
            while b"\n" in self.got:
                l, self.got = self.got.split(b"\n", 1)
                m = json.loads(l)
                if want is None or all(m.get(k) == v for k, v in want.items()):
                    return m
            r, _, _ = select.select([self.mac], [], [], max(0.0, end - time.monotonic()))
            if r:
                self.got += self.mac.recv(65536)
        self.fail(f"no line {want} from the agent within {wait} s")

    def drain(self):
        while True:
            try:
                d = self.mac.recv(65536)
            except BlockingIOError:
                return
            if not d:
                return
            self.got += d

    def mac_says(self, **m):
        self.mac.sendall(json.dumps(m).encode() + b"\n")

    def status(self):
        return json.loads((pathlib.Path(self.tmp) / "omacvm/media").read_text())

    def test_the_mac_controls_the_player_that_plays(self):
        self.start("fakea", "Fake A")
        hello = self.line({"t": "hello"})
        # Left in the port from an earlier run: never acted on.
        self.mac_says(t="hello", v=1, on=True, n="old")
        self.mac_says(t="cmd", c="play")
        self.mac_says(t="hello", v=1, on=True, n=hello["n"])
        self.assertEqual(self.line({"t": "state"})["s"], "none", "a stopped player that never played: none")
        self.assertEqual(self.calls("fakea", wait=0.5), "", "the old command was not run")

        self.tell("fakea", "title SECRET Song")
        self.tell("fakea", "play")
        s = self.line({"t": "state", "s": "playing"})
        self.assertEqual((s["player"], s["title"], s["artist"], s["len"], s["pos"], s["next"], s["prev"]),
                         ("Fake A", "SECRET Song", "Fake Band", 60.0, 5.0, True, False))

        self.mac_says(t="cmd", c="pause")
        self.assertEqual(self.calls("fakea"), "call Pause")
        self.line({"t": "state", "s": "paused"})
        self.mac_says(t="cmd", c="play")
        self.assertEqual(self.calls("fakea"), "call Play")
        self.line({"t": "state", "s": "playing"})
        self.mac_says(t="cmd", c="next")
        self.assertEqual(self.calls("fakea"), "call Next")

        self.start("fakeb", "Fake B")
        self.tell("fakeb", "play")
        self.assertEqual(self.line({"t": "state", "s": "playing", "player": "Fake B"})["player"], "Fake B",
                         "the player that went into Playing last")
        self.mac_says(t="cmd", c="pause")
        self.assertEqual(self.calls("fakeb"), "call Pause", "the command goes to the player the Mac shows")
        self.assertEqual(self.line({"t": "state", "s": "playing"})["player"], "Fake A", "A still plays: A again")

        self.tell("fakeb", "quit")
        self.tell("fakea", "quit")
        self.line({"t": "state", "s": "none"})
        self.assertEqual(self.status()["mac"], "on")

        self.mac_says(t="hello", v=1, on=False, n=hello["n"])
        time.sleep(0.5)
        self.assertEqual(self.status()["mac"], "off")
        self.mac.setblocking(False)
        self.got = b""
        self.drain()
        self.got = b""
        self.start("fakec", "Fake C")
        self.tell("fakec", "play")
        time.sleep(1.5)
        self.drain()
        self.assertNotIn(b'"state"', self.got, "off: no states")

        self.agent.terminate()
        self.agent.wait()
        self.assertNotIn("SECRET", (pathlib.Path(self.tmp) / "omacvm/media").read_text())
        for p in ("fakea", "fakeb"):
            self.assertNotIn("PlayPause", self.players[p].stdout.read())

    def test_a_restarted_agent_keeps_a_paused_player(self):
        self.start("fakea", "Fake A")
        self.tell("fakea", "play")
        self.tell("fakea", "pause")
        time.sleep(0.3)
        hello = self.line({"t": "hello"})
        self.mac_says(t="hello", v=1, on=True, n=hello["n"])
        s = self.line({"t": "state"})
        self.assertEqual((s["s"], s["player"]), ("paused", "Fake A"), "at start: a paused player")


if __name__ == "__main__":
    unittest.main()
