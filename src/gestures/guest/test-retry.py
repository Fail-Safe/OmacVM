#!/usr/bin/env python3
"""Offline test of the guest daemon's reconnects (src/gestures/mac/test.sh):
serve() with run() replaced, a made-up clock and no sleeping. No VM, no uinput.
  - without the Mac's helper: a try every 2 s for the first 30 s, then every 10 s;
  - one log line per outage, not one per try;
  - after the helper took a connection, the next outage starts quick again;
  - "the way to the Mac changed" connects again at once, without a wait.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys
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


class Held:
    def release(self):
        pass


class Done(Exception):
    pass


fails = 0


def expect(what, ok, got=""):
    global fails
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f" (got {got})"))
    fails += not ok


def session(script, tries):
    """Run serve() over `script`: a list of 'refused', 'connected' (the helper
    took it, then it went) or 'moved'. Returns the waits and the log."""
    now = [0.0]
    waits = []
    steps = iter(script)

    def run(pad, keys, glide):
        step = next(steps, None)
        if step is None:
            raise Done()
        if step == "connected":
            g.CONNECTED.set()
            raise ConnectionError("helper closed the connection")
        if step == "moved":
            raise g.Moved("the way to the Mac changed (now 10.0.2.2): connecting again")
        raise ConnectionRefusedError(111, "Connection refused")

    def sleep(s):
        waits.append(s)
        now[0] += s
        if len(waits) > tries:
            raise Done()

    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        try:
            g.serve(Held(), Held(), Held(), run=run, sleep=sleep, clock=lambda: now[0])
        except Done:
            pass
    return waits, err.getvalue().splitlines()


# A helper that never comes: 2 s for the first 30 s, then 10 s; one line.
waits, log = session(["refused"] * 40, 40)
expect("first 30 s: a try every 2 s", waits[:15] == [2.0] * 15, waits[:16])
expect("then every 10 s", all(w == 10.0 for w in waits[15:]) and len(waits) > 20, waits[15:20])
expect("one log line for the whole outage", len(log) == 1, log)
expect("the line says the cadence", "every 2 s" in log[0] and "every 10 s" in log[0], log)

# It comes back (connects), then goes again: the second outage is quick again and logs again.
waits, log = session(["refused"] * 20 + ["connected"] + ["refused"] * 3, 30)
expect("before the helper came: slow at the end", waits[19] == 10.0, waits[15:21])
expect("after a connection: quick tries again", waits[20:23] == [2.0, 2.0, 2.0], waits[20:24])
expect("one line per outage (two outages)", len(log) == 2, log)

# The way to the Mac changed: at once, no wait, and it is no outage.
waits, log = session(["moved", "refused", "refused"], 5)
expect("moved: connects again without a wait", waits == [2.0, 2.0], waits)
expect("moved: said once, then one outage line", len(log) == 2 and "changed" in log[0], log)

expect("retry_wait at 0 s", g.retry_wait(0) == 2.0, g.retry_wait(0))
expect("retry_wait at 29.9 s", g.retry_wait(29.9) == 2.0, g.retry_wait(29.9))
expect("retry_wait at 30 s", g.retry_wait(30) == 10.0, g.retry_wait(30))
sys.exit(1 if fails else 0)
