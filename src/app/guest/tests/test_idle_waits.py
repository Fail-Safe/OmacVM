#!/usr/bin/env python3
"""How long the guest agents sleep while nothing happens (no VM needed).

    python3 src/app/guest/tests/test_idle_waits.py
"""
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


camera = load("omacvm_camera", "src/camera/guest/omacvm-camera")
clipboard = load("omacvm_clipboard", "src/app/guest/omacvm-clipboard")


class Camera(unittest.TestCase):
    def test_unused_camera_sleeps(self):
        self.assertEqual(camera.wait_ms(False, 100.0, 0.0), -1)
        self.assertEqual(camera.wait_ms(False, 100.0, 99.0), -1)   # quiet time over

    def test_quiet_port_is_looked_at_again(self):
        self.assertEqual(camera.wait_ms(False, 100.0, 100.5), 501)
        self.assertGreaterEqual(camera.wait_ms(False, 100.0, 100.0001), 1)

    def test_reading_app_keeps_the_fast_loop(self):
        self.assertEqual(camera.wait_ms(True, 100.0, 0.0), 200)


class Clipboard(unittest.TestCase):
    def test_watcher_exit_wakes_the_loop(self):
        import select
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.2)"])
        fd = clipboard.exit_fd(child.pid)
        if fd is None:
            child.wait()
            self.assertNotEqual(sys.platform, "linux", "no pidfd on Linux")   # the guest has one
            self.skipTest("no pidfd here (the agent looks once a second)")
        try:
            self.assertEqual(select.select([fd], [], [], 5)[0], [fd])
            self.assertIsNotNone(child.poll())
        finally:
            os.close(fd)


class BridgeEvents(unittest.TestCase):
    """The session's event stream service (bridge/guest/omacvm-bridge-events)
    sleeps until it has something to do, not every second."""

    def setUp(self):
        self.ev = load("omacvm_bridge_events", "src/bridge/guest/omacvm-bridge-events")

    def test_nothing_to_do_no_timeout(self):
        self.ev.upstream, self.ev.clients = None, {}
        self.assertIsNone(self.ev.next_wait(100.0, []))

    def test_mac_stream_silence_limit(self):
        self.ev.upstream, self.ev.clients, self.ev.up_last = object(), {}, 100.0
        self.assertAlmostEqual(self.ev.next_wait(101.0, [object()]), self.ev.SILENCE - 1.0)

    def test_linger_after_the_last_client(self):
        self.ev.upstream, self.ev.clients = object(), {}
        self.ev.up_last, self.ev.idle_since = 100.0, 110.0
        self.assertAlmostEqual(self.ev.next_wait(111.0, []), min(self.ev.SILENCE - 11.0, self.ev.LINGER - 1.0))

    def test_retry_a_new_stream(self):
        self.ev.upstream, self.ev.clients, self.ev.up_started = None, {}, 100.0
        self.assertAlmostEqual(self.ev.next_wait(101.0, [object()]), self.ev.RETRY - 1.0)

    def test_client_that_never_asks(self):
        c = self.ev.Client.__new__(self.ev.Client)
        c.streaming, c.since = False, 100.0
        self.ev.upstream, self.ev.clients = None, {3: c}
        self.assertAlmostEqual(self.ev.next_wait(102.0, []), 3.0)
        self.assertEqual(self.ev.next_wait(110.0, []), 0.05)   # overdue: at once, not a spin

    def test_idle_service_hardly_wakes(self):
        """The live service with a client and a silent Mac stream: about no
        wakeups in 3 s (it woke every second). Linux only (/proc)."""
        import socket
        import tempfile
        import time
        if not os.path.exists("/proc/self/status"):
            self.skipTest("no /proc here (Linux: the guest)")
        with tempfile.TemporaryDirectory() as d:
            stub = os.path.join(d, "client")
            with open(stub, "w") as f:
                f.write('#!/bin/sh\nprintf "event: wifi\\ndata: {}\\n\\n"\nexec sleep 60\n')
            os.chmod(stub, 0o755)
            env = dict(os.environ, OMACVM_BRIDGE_EVENTS_SOCKET=os.path.join(d, "s"), OMACVM_BRIDGE_CLIENT=stub)
            svc = subprocess.Popen([sys.executable, str(ROOT / "src/bridge/guest/omacvm-bridge-events")],
                                   env=env, stderr=subprocess.DEVNULL)
            try:
                for _ in range(50):
                    if os.path.exists(env["OMACVM_BRIDGE_EVENTS_SOCKET"]):
                        break
                    time.sleep(0.1)
                c = socket.socket(socket.AF_UNIX)
                c.connect(env["OMACVM_BRIDGE_EVENTS_SOCKET"])
                c.sendall(b"GET /events HTTP/1.1\r\nHost: omacvm-bridge\r\n\r\n")
                c.settimeout(5)
                got = b""
                while b"data: {}" not in got:
                    got += c.recv(4096)
                time.sleep(0.5)

                def switches():
                    with open(f"/proc/{svc.pid}/status") as f:
                        return sum(int(line.split()[1]) for line in f if "ctxt_switches" in line)
                before = switches()
                time.sleep(3)
                self.assertLessEqual(switches() - before, 1)
                c.close()
            finally:
                svc.terminate()
                svc.wait(5)


if __name__ == "__main__":
    unittest.main()
