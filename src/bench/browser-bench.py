#!/usr/bin/env python3
"""Run a browser benchmark in Chrome/Chromium and print its score.

  browser-bench.py speedometer|jetstream|motionmark|aquarium|basemark|webgpu|scroll [--port 9222]

The browser must already run with --remote-debugging-port (see bench.sh).
Talks to it over the DevTools protocol; Python's standard library only.
"""
import base64, json, os, socket, struct, sys, time, urllib.request

SCROLL_JS = r"""
(async () => {
  const gb = window.chrome && chrome.gpuBenchmarking;
  if (!gb || !gb.smoothScrollBy) return JSON.stringify({error: "no chrome.gpuBenchmarking (--enable-gpu-benchmarking)"});
  window.scrollTo(0, 0);
  await new Promise(r => setTimeout(r, 1000));
  const dist = Math.min(document.documentElement.scrollHeight - innerHeight - 50, 15000);
  const t = []; let on = true;
  const tick = ts => { t.push(ts); if (on) requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
  const t0 = performance.now();
  await new Promise(res => gb.smoothScrollBy(dist, res, innerWidth / 2, innerHeight / 2, gb.MOUSE_INPUT, "down", 1500, true));
  on = false;
  const secs = (performance.now() - t0) / 1000;
  const d = []; for (let i = 1; i < t.length; i++) d.push(t[i] - t[i - 1]);
  d.sort((a, b) => a - b);
  const pct = p => d.length ? d[Math.min(d.length - 1, Math.floor(p * d.length))] : 0;
  const late = d.filter(x => x > 1.5 * pct(0.5)).length;
  return JSON.stringify({fps: +(t.length / secs).toFixed(1), p50: +pct(0.5).toFixed(2), p95: +pct(0.95).toFixed(2),
    p99: +pct(0.99).toFixed(2), late_pct: +(100 * late / Math.max(1, d.length)).toFixed(1), scrolled: Math.round(scrollY)});
})()
"""

TESTS = {
    # Speedometer 3.1: browser and CPU speed (score: runs per minute).
    "speedometer": {
        "url": "https://browserbench.org/Speedometer3.1/",
        "start": "document.querySelector('.start-tests-button').click()",
        "done": "(() => { const r = document.querySelector('#result-number');"
                " return location.hash === '#summary' && r ? r.textContent.trim() : '' })()",
        "timeout": 900,
    },
    # JetStream 2.2: JavaScript and WebAssembly (score: geometric mean). It loads
    # about a hundred files first; the Start link shows when they are all in.
    "jetstream": {
        "url": "https://browserbench.org/JetStream2.2/",
        "ready": "!!document.querySelector('#status a.button')",
        "start": "JetStream.start()",
        "done": "(() => { const r = document.querySelector('#result-summary.done .score');"
                " return r ? r.textContent.trim() : '' })()",
        "timeout": 1200,
    },
    # MotionMark 1.3.1: graphics (animations drawn by the GPU through the browser).
    # Its score reads "1234.56 @ 120fps"; the number before the @ counts.
    "motionmark": {
        "url": "https://browserbench.org/MotionMark1.3.1/",
        "start": "benchmarkController.startBenchmark()",
        "done": "(() => { const r = document.querySelector('#results .score');"
                " return r && document.querySelector('#results.selected') ? r.textContent.trim().split(' ')[0] : '' })()",
        # Each subtest's score: one at its minimum drags the whole score down.
        "detail": "(document.querySelector('#results-tables') || document.body).innerText.replace(/\\s+/g, ' ').slice(0, 1500)",
        "timeout": 900,
    },
    # WebGL Aquarium: real 3D load, frames per second with 30,000 fish,
    # averaged over 20 s after 10 s of warm-up (about 40 s in all).
    "aquarium": {
        "url": "https://webglsamples.org/aquarium/aquarium.html?numFish=30000",
        "start": "setSetting(document.getElementById('setSetting0'), 0)",
        "sample": "typeof g_fpsTimer !== 'undefined' ? g_fpsTimer.averageFPS : 0",
        "warmup": 10, "seconds": 20,
    },
    # Basemark Web 3.0: WebGL, canvas and SVG, plus some JavaScript and page
    # tests (about 2 minutes). It ends on its result page on powerboard.gpuscore.com.
    "basemark": {
        "url": "https://web.basemark.com/",
        "start": "document.getElementById('start').click()",
        "done": "(() => { const r = document.querySelector('.device-scores__score');"
                " return /benchmark-result/.test(location.pathname) && r ? r.textContent.trim() : '' })()",
        "detail": "location.href + ' ' + (document.body.innerText.replace(/\\s+/g, ' ').split('RESULT')[1] || '').slice(0, 700)",
        "timeout": 900,
    },
    # Scrolling: Chrome's own scroll gesture (the compositor's path, as a
    # trackpad or a wheel) down a long real page at 1500 px/s, 10 s, with the
    # time of every animation frame. Score: frames per second; the frame-time
    # percentiles and the share of late frames (over 1.5 frames) go to stderr.
    # Needs Chrome started with --enable-gpu-benchmarking (bench.sh does).
    "scroll": {
        "url": "https://en.wikipedia.org/wiki/Apple_Inc.",
        "ready": "document.readyState === 'complete'",
        "settle": 4,
        "eval": SCROLL_JS,
        "key": "fps",
    },
    # WebGPU compute: f32 matrix multiply 2048 x 2048 in GFLOPS (pages/webgpu-matmul.html, about
    # 10 s). Pages without a hardware adapter report "error: no adapter".
    "webgpu": {
        "url": "pages/webgpu-matmul.html",
        "start": "document.getElementById('result')",
        "done": "(() => { const r = document.getElementById('result');"
                " return r && r.dataset.done ? r.textContent : '' })()",
        "detail": "document.getElementById('detail').textContent",
        "timeout": 300,
    },
}


class DevTools:
    def __init__(self, ws_url):
        host, path = ws_url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.s.recv(4096)
        if b" 101 " not in resp.split(b"\r\n")[0]:
            raise SystemExit("DevTools refused the connection")
        self.buf = resp.split(b"\r\n\r\n", 1)[1]
        self.id = 0

    def _send(self, text):
        data = text.encode()
        head = bytearray([0x81])
        n = len(data)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126); head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127); head += struct.pack(">Q", n)
        mask = os.urandom(4)
        head += mask
        self.s.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("DevTools connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _recv(self):
        msg = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            msg += self._read(n)
            if b0 & 0x80:
                return json.loads(msg)

    def call(self, method, **params):
        self.id += 1
        self._send(json.dumps({"id": self.id, "method": method, "params": params}))
        while True:
            m = self._recv()
            if m.get("id") == self.id:
                return m.get("result", {})

    def js(self, expr, wait=False):
        r = self.call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=wait)
        return r.get("result", {}).get("value")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in TESTS:
        raise SystemExit(__doc__)
    t = TESTS[sys.argv[1]]
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 9222
    base = f"http://127.0.0.1:{port}"
    req = urllib.request.Request(f"{base}/json/new?about:blank", method="PUT")
    tab = json.load(urllib.request.urlopen(req))
    try:
        run(DevTools(tab["webSocketDebuggerUrl"]), t)
    finally:   # close the tab: a page left open can keep drawing during the next test
        try:
            urllib.request.urlopen(f"{base}/json/close/{tab['id']}")
        except OSError:
            pass


def run(dt, t):
    dt.call("Page.enable")
    dt.call("Page.bringToFront")
    url = t["url"]
    if not url.startswith("http"):   # a page that ships beside this script
        url = "file://" + os.path.join(os.path.dirname(os.path.abspath(__file__)), url)
    ready = t.get("ready") or "typeof " + t["start"].split("(")[0].split(".")[0] + " !== 'undefined'"
    for attempt in (1, 2):   # a page that never got ready (a lost download) is loaded once more
        dt.call("Page.navigate", url=url)
        for _ in range(120):
            time.sleep(1)
            if dt.js("document.readyState") == "complete" and dt.js(ready):
                break
        else:
            if attempt == 2:
                raise SystemExit(f"{sys.argv[1]}: the page did not get ready")
            continue
        break
    time.sleep(t.get("settle", 2))
    # The page size, for the log: it should be the same everywhere.
    print("viewport " + str(dt.js("innerWidth + 'x' + innerHeight + ' at ' + devicePixelRatio + 'x'")), file=sys.stderr)
    if "eval" in t:   # one script that measures and returns JSON
        o = json.loads(dt.js(t["eval"], wait=True) or "{}")
        print(json.dumps(o), file=sys.stderr)
        if t["key"] not in o:
            raise SystemExit(f"{sys.argv[1]}: {o.get('error', 'no result')}")
        print(o[t["key"]])
        return
    dt.js(t["start"])
    if "sample" in t:
        time.sleep(t["warmup"])
        fps = []
        for _ in range(t["seconds"]):
            time.sleep(1)
            v = dt.js(t["sample"])
            if isinstance(v, (int, float)) and v > 0:
                fps.append(v)
        if not fps:
            raise SystemExit(f"{sys.argv[1]}: no frames")
        print(f"{sum(fps) / len(fps):.1f}")
        return
    start = time.time()
    while time.time() - start < t["timeout"]:
        time.sleep(5)
        score = dt.js(t["done"])
        if score:
            print(score)
            if "detail" in t:   # to stderr, for the log
                print(dt.js(t["detail"]), file=sys.stderr)
            return
    raise SystemExit(f"{sys.argv[1]}: no score after {t['timeout']} s")


if __name__ == "__main__":
    main()
