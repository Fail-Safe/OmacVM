#!/usr/bin/env python3
# freeze.py SECONDS OUT.json: how long the guest's own clock saw a 1 ms sleeper stall
# (run real-time, chrt -f 50: then a gap is the VM not running, not guest scheduling).
import json, sys, time
dur, out = float(sys.argv[1]), sys.argv[2]
b = {"5-9": 0, "10-19": 0, "20-49": 0, "50-99": 0, ">=100": 0}
worst, events = 0.0, []
t0 = last = time.monotonic()
while last - t0 < dur:
    time.sleep(0.001)
    t = time.monotonic(); g = (t - last) * 1000 - 1; last = t
    if g >= 5:
        k = ">=100" if g >= 100 else "50-99" if g >= 50 else "20-49" if g >= 20 else "10-19" if g >= 10 else "5-9"
        b[k] += 1; worst = max(worst, g)
        if g >= 20: events.append([round(t - t0, 3), round(g, 1)])
json.dump({"gaps": b, "worst_ms": round(worst, 1), "events_ge20": events[:400]}, open(out, "w"))
