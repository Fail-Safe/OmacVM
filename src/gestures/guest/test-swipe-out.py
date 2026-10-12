#!/usr/bin/env python3
"""Offline test of Swipe out to macOS in the guest daemon (src/gestures/mac/test.sh):
the daemon's own handle() with evdev stubbed, against a made-up Hyprland on a
Unix socket (j/monitors, j/workspaces, j/getoption, dispatch). No VM, no uinput.
  off until the Mac says "X on"; "X off" turns it off again;
  past the lowest workspace of the focused display -> "X left";
  past the last one: the first swipe from a workspace with windows is
  Hyprland's (a new empty one), from the empty last one -> "X right";
  workspace_swipe_invert and _create_new followed; a Magic Mouse's swipe
  (four fingers, at most 0.35 of the width) counts; short, up-and-down and
  two-finger touches, a special workspace or no Hyprland: nothing;
  after "X right" Hyprland's new empty workspace goes back to the one the
  swipe began on; no notices on "S esc" or "N".
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import time
import types


class _Codes:
    def __getattr__(self, name):
        return 0


evdev = types.ModuleType("evdev")
evdev.AbsInfo = object
evdev.UInput = object
evdev.ecodes = _Codes()
sys.modules["evdev"] = evdev
DAEMON = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "omacvm-gestures")
loader = importlib.machinery.SourceFileLoader("omacvm_gestures_daemon", DAEMON)
spec = importlib.util.spec_from_loader(loader.name, loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)

fails = 0


def check(ok, what):
    global fails
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    fails += 0 if ok else 1


# ---- the made-up Hyprland ----
class Hypr:
    def __init__(self):
        self.monitors = []
        self.workspaces = []
        self.options = {"gestures:workspace_swipe_invert": 1, "gestures:workspace_swipe_create_new": 1}
        self.requests = []
        self.after_swipe = None   # (monitors, workspaces) Hyprland shows once a request came after the lift
        self.lifted = False
        self.old_options = False  # answer options as Hyprland before 0.56 did ({"int": 1})

    def world(self, active, ids, windows=None, monitor="Virtual-1", others=(), special=0):
        windows = windows or {}
        self.monitors = [{"name": monitor, "focused": True, "activeWorkspace": {"id": active, "name": str(active)},
                          "specialWorkspace": {"id": special, "name": ""}}]
        for name, act in others:
            self.monitors.append({"name": name, "focused": False, "activeWorkspace": {"id": act, "name": str(act)},
                                  "specialWorkspace": {"id": 0, "name": ""}})
        self.workspaces = [{"id": i, "name": str(i), "monitor": monitor, "windows": windows.get(i, 0)} for i in ids]
        for name, act in others:
            self.workspaces.append({"id": act, "name": str(act), "monitor": name, "windows": 1})
        self.after_swipe = None
        self.lifted = False

    def answer(self, req):
        self.requests.append(req)
        if self.lifted and self.after_swipe and req.startswith("j/"):
            self.monitors, self.workspaces = self.after_swipe
            self.after_swipe = None
        if req == "j/monitors":
            return json.dumps(self.monitors)
        if req == "j/workspaces":
            return json.dumps(self.workspaces)
        if req.startswith("j/getoption "):
            name = req.split(" ", 1)[1]
            if name not in self.options:
                return "no such option"
            # Hyprland 0.56 answers a bool option with "bool"; older ones with "int".
            key = "int" if self.old_options else "bool"
            return json.dumps({"option": name, key: self.options[name] if key == "int" else bool(self.options[name]), "set": False})
        if req.startswith("dispatch "):
            return "ok"
        return "unknown request"


H = Hypr()
tmp = tempfile.mkdtemp()
SOCK = os.path.join(tmp, ".socket.sock")
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
srv.listen(8)


def serve():
    while True:
        c, _ = srv.accept()
        with c:
            req = c.recv(4096).decode()
            c.sendall(H.answer(req).encode())


threading.Thread(target=serve, daemon=True).start()
g.hypr_socket = lambda: SOCK

sent = []
g.SWIPE.send = lambda b: sent.append(b.decode().strip())
shown = []
g.notify = lambda text, ms=2500: shown.append(text) or True
g.ESC_HINT_FILE = os.path.join(tmp, "escape-hint-shown")


class Held:
    def release(self):
        pass

    def frame(self, contacts):
        pass


def line(text):
    g.handle(text.encode().split(), Held(), Held(), Held())


g.set_mac(1, 15600, 9600)   # the 16" MacBook Pro's trackpad (1/100 mm)


def swipe(dx, dy=0.0, fingers=4, steps=8, x0=0.5):
    """Fingers from x0 sideways by dx (a share of the trackpad), dy up or down; then lifted."""
    sent.clear()
    for k in range(steps + 1):
        f = k / steps
        parts = [str(fingers)]
        for i in range(fingers):
            parts += [str(10 + i), f"{x0 - 0.1 + 0.05 * i + dx * f:.5f}", f"{0.5 + dy * f:.5f}", "0.5"]
        line("F " + " ".join(parts))
        time.sleep(0.004)
    H.lifted = True
    line("F 0")
    return list(sent)


# ---- off until the Mac says so ----
H.world(1, [1, 2, 3], {1: 2, 2: 1, 3: 1})
H.requests.clear()
check(swipe(0.3) == [] and H.requests == [], "off (no X on yet): a swipe past the first workspace sends nothing, asks Hyprland nothing")
line("X on")
check(g.SWIPE.on, "X on: on")

# ---- left: past the lowest workspace (invert on: fingers to the right = the previous workspace) ----
H.world(1, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(0.3) == ["X left"], "workspace 1 of 1..3, swipe toward the previous: X left")
H.world(2, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(0.3) == [], "workspace 2 of 1..3, the same swipe: Hyprland's (to 1), nothing sent")
H.world(3, [3, 5], {3: 1, 5: 1})
check(swipe(0.3) == ["X left"], "workspace 3, the lowest that exists (1 and 2 do not): X left")

# ---- right: Hyprland makes a new empty workspace first ----
H.world(3, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(-0.3) == [], "last workspace (3) with windows, toward the next: Hyprland makes a new one, nothing sent")
H.world(4, [1, 2, 3, 4], {1: 2, 2: 1, 3: 1, 4: 0})
H.requests.clear()
H.after_swipe = ([{"name": "Virtual-1", "focused": True, "activeWorkspace": {"id": 5, "name": "5"},
                   "specialWorkspace": {"id": 0, "name": ""}}],
                 [{"id": i, "name": str(i), "monitor": "Virtual-1", "windows": w} for i, w in ((1, 2), (2, 1), (3, 1), (5, 0))])
check(swipe(-0.3) == ["X right"], "the empty last workspace (4), toward the next: X right")
time.sleep(0.8)
check('dispatch hl.dsp.focus({ workspace = "4" })' in H.requests,
      "... Hyprland's swipe had gone on to a new empty 5: back to 4 (as it was when the person comes back)")
H.world(2, [1, 2, 3], {1: 1, 2: 0, 3: 1})
check(swipe(-0.3) == [], "an empty workspace in the middle, toward the next: Hyprland's")
H.options["gestures:workspace_swipe_create_new"] = 0
H.world(3, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(-0.3) == ["X right"], "workspace_swipe_create_new off: the last workspace with windows: X right at once")
H.options["gestures:workspace_swipe_create_new"] = 1

# ---- invert off: fingers to the right = the next workspace ----
H.options["gestures:workspace_swipe_invert"] = 0
H.world(1, [1, 2], {1: 1, 2: 0})
check(swipe(-0.3) == ["X left"], "invert off: fingers to the left from the first: X left")
H.world(2, [1, 2], {1: 1, 2: 0})
check(swipe(0.3) == ["X right"], "invert off: fingers to the right from the empty last: X right")
H.old_options = True
H.world(1, [1, 2], {1: 1, 2: 0})
check(swipe(-0.3) == ["X left"], "invert off, said as before Hyprland 0.56 ({\"int\": 0}): the same")
H.options["gestures:workspace_swipe_invert"] = 1
check(swipe(0.3) == ["X left"] and swipe(-0.3) == [], "invert on, said as {\"int\": 1}: fingers to the right from the first: X left")
H.old_options = False

# ---- not a swipe out ----
H.world(1, [1, 2, 3], {1: 2})
check(swipe(0.08) == [], "a short swipe (8 % of the width): nothing")
check(swipe(0.25, dy=0.3) == [], "mostly up or down: nothing")
check(swipe(0.3, fingers=2) == [], "two fingers (scrolling): nothing")
check(swipe(0.3, fingers=3) == ["X left"], "three fingers: counts (Hyprland swipes workspaces with 3 and 4)")
H.world(1, [1, 2, 3], {1: 2}, special=-98)
check(swipe(0.3) == [], "a special workspace open (the scratchpad): nothing")

# ---- a Magic Mouse: four virtual fingers, at most 0.35 of the width, from the middle ----
H.world(1, [1, 2], {1: 1})
check(swipe(0.35, fingers=4) == ["X left"], "Magic Mouse swipe (4 virtual fingers, 0.35 of the width): X left")
H.world(2, [1, 2], {1: 1, 2: 0})
check(swipe(-0.2, fingers=3) == ["X right"], "Magic Mouse swipe with MouseSwipeFingers 3, toward the next from the empty last: X right")

# ---- another display: its own workspaces ----
H.world(11, [11, 12], {11: 1, 12: 1}, monitor="Virtual-2", others=[("Virtual-1", 1)])
check(swipe(0.3) == ["X left"], "the focused display Virtual-2, its lowest (11): X left (Virtual-1's 1 does not count)")
H.world(12, [11, 12], {11: 1, 12: 1}, monitor="Virtual-2", others=[("Virtual-1", 1)])
check(swipe(0.3) == [], "... from its 12: Hyprland's")

# ---- the workspaces as they were at the swipe's start ----
H.world(1, [1, 2], {1: 1, 2: 1})
H.after_swipe = None
sent.clear()
for k in range(9):
    f = k / 8
    line("F 4 " + " ".join(f"{10 + i} {0.4 + 0.05 * i + 0.3 * f:.5f} 0.5 0.5" for i in range(4)))
    if k == 0:
        time.sleep(0.05)   # the start was read: now Hyprland moves on (as its swipe would)
        H.world(2, [1, 2], {1: 1, 2: 1})
line("F 0")
check(sent == ["X left"], "Hyprland changed during the swipe: the start counts (it began on 1): X left")

# ---- no Hyprland ----
real = g.hypr_socket
g.hypr_socket = lambda: None
check(swipe(0.3) == [], "Hyprland does not answer: nothing")
g.hypr_socket = os.path.join(tmp, "gone.sock").__str__
check(swipe(0.3) == [], "Hyprland's socket gone: nothing")
g.hypr_socket = real

# ---- the capture ends mid-swipe; off again ----
H.world(1, [1, 2, 3], {1: 2})
sent.clear()
line("F 4 10 0.4 0.5 0.5 11 0.45 0.5 0.5 12 0.5 0.5 0.5 13 0.55 0.5 0.5")
line("S esc ctrl-opt")
line("F 4 10 0.7 0.5 0.5 11 0.75 0.5 0.5 12 0.8 0.5 0.5 13 0.85 0.5 0.5")
line("F 0")
check(sent == [], "S esc during a swipe: that swipe is dropped")
line("X off")
check(not g.SWIPE.on and swipe(0.3) == [], "X off: nothing")
line("X on")

# ---- no notices any more (user, 2026-10-12) ----
shown.clear()
for text in ("S esc", "S esc ctrl-opt", "N space-shortcut-off", "N space-unchanged", "N no-spaces", "N some-new-word"):
    line(text)
check(shown == [], "no notice on S esc, S esc ctrl-opt or N <why>")
line("S esc ctrl-opt-cmd")
check(len(shown) == 1 and "New shortcut" in shown[0], "the old ⌃⌥⌘ Esc: the new one is named, once per VM")
line("S esc ctrl-opt-cmd")
check(len(shown) == 1, "... not again")

# ---- the rule on its own ----
st = {"active": 1, "ids": [1, 2], "empty": False, "special": False, "invert": True, "create_new": True}
w = 15600
check(g.swipe_out_side(st, 0.2 * w, 0, w) == "left" and g.swipe_out_side(st, -0.2 * w, 0, w) is None,
      "rule: first of two, previous: left; next: Hyprland's")
check(g.swipe_out_side(None, 0.2 * w, 0, w) is None and g.swipe_out_side({}, 0.2 * w, 0, w) is None,
      "rule: no workspaces known: nothing")
check(g.swipe_out_side(dict(st, ids=[]), 0.2 * w, 0, w) == "left", "rule: no list (only the active one): its own edge")
sys.exit(1 if fails else 0)
