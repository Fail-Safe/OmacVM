// The sound delay the app tells a VM (OmacVMAudio), without a VM:
//   cd app/app && swift run audio-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMAudio

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.05 } ?? false }

// AirPods Pro as outlat read them on the MacBook Pro (2026-10-06); a wired
// display's speakers with the same 12.8 ms total as the Mac mini's LG.
let airpods = AudioDelay.Device(latency: 7680, safetyOffset: 0, streamLatency: 0, bufferFrames: 512, sampleRate: 48000)
let lg = AudioDelay.Device(latency: 0, safetyOffset: 102, streamLatency: 0, bufferFrames: 512, sampleRate: 48000)
expect(near(airpods.ms, 170.7), "AirPods Pro: 7680 + 512 frames at 48 kHz = 170.7 ms")
expect(near(lg.ms, 12.8), "wired: 102 + 512 frames at 48 kHz = 12.8 ms")

// Totals: QEMU's part plus the device.
expect(AudioDelay.total(deviceMs: airpods.ms) == AudioDelay.qemuMs + 171, "AirPods: QEMU + 171 ms")
expect(AudioDelay.total(deviceMs: lg.ms) == AudioDelay.qemuMs + 13, "wired: QEMU + 13 ms")
expect(AudioDelay.total(deviceMs: nil) == AudioDelay.qemuMs, "unknown device: QEMU's part alone")

// The sound's own thread (AudioPath): its smaller buffers, its own QEMU part.
expect(AudioDelay.qemuPart(thread: false) == AudioDelay.qemuMs, "main loop path: QEMU's part as before")
expect(AudioDelay.qemuPart(thread: true) == AudioDelay.qemuThreadMs, "own thread: its QEMU part")
expect(AudioDelay.qemuThreadMs < AudioDelay.qemuMs, "own thread: QEMU's part is smaller")
expect(AudioDelay.total(deviceMs: lg.ms, thread: true) == AudioDelay.qemuThreadMs + 13, "own thread, wired: QEMU + 13 ms")
expect(AudioPath.threadOptions.contains("out.frequency=48000") && AudioPath.threadOptions.contains("in.frequency=48000"),
       "own thread: 48 kHz both ways (the probe's loopback and the Mac's devices)")
expect(AudioPath.threadOptions.contains("out.buffer-count=6") && AudioPath.threadOptions.contains("out.buffer-length=5334"),
       "own thread: ring 6 x 256 frames")
expect(AudioPath.mainLoopOptions == "out.buffer-count=8", "main loop path: 3.1.14's ring")

// The playback buffers QEMU asks the Mac's output for (#548): AirPods refused
// the own thread's queue (48 kHz, 6 x 256 frames; AudioQueueStart -66681) and
// played the main loop's (44.1 kHz, 4 x 512).
let blue = AudioOutputSize.fourCC("blue"), blea = AudioOutputSize.fourCC("blea"), airp = AudioOutputSize.fourCC("airp")
expect(blue == 0x626C_7565, "'blue' is kAudioDeviceTransportTypeBluetooth")
expect(AudioOutputSize.minimumFrames(transport: blue) == 512, "Bluetooth output (AirPods): at least 512 frames")
expect(AudioOutputSize.minimumFrames(transport: blea) == 512, "Bluetooth LE output: at least 512 frames")
expect(AudioOutputSize.minimumFrames(transport: airp) == 512, "AirPlay output: at least 512 frames")
expect(AudioOutputSize.minimumFrames(transport: AudioOutputSize.fourCC("bltn")) == 0, "built-in speakers: the path's own size")
expect(AudioOutputSize.minimumFrames(transport: AudioOutputSize.fourCC("usb ")) == 0, "USB interface: the path's own size")
expect(AudioOutputSize.minimumFrames(transport: nil) == 0, "no device: the path's own size")
expect(AudioOutputSize.fileText(frames: 512) == "512\n" && AudioOutputSize.fileText(frames: 0) == "0\n", "the file QEMU reads: a number and a newline")
// The start's options: a wireless output gives the own thread the main loop's queue.
expect(AudioPath.options(thread: true, wireless: false) == AudioPath.threadOptions, "own thread, wired: 48 kHz, 6 x 256")
expect(AudioPath.options(thread: false, wireless: true) == AudioPath.mainLoopOptions, "main loop: its options either way")
let w = AudioPath.options(thread: true, wireless: true)
expect(w.contains("out.frequency=44100") && w.contains("out.buffer-length=11610"),
       "own thread, wireless: QEMU's main loop queue (44.1 kHz, 512 frames: 11610 us as QEMU's default)")
expect(w.contains("out.buffer-count=4") && w.contains("in.frequency=48000") && w.contains("in.buffer-length=10667"),
       "own thread, wireless: ring of 4 buffers (46 ms), recording as before")
expect(AudioOutputSize.ownFrames(thread: true) == 256 && AudioOutputSize.ownFrames(thread: true, wireless: true) == 512
       && AudioOutputSize.ownFrames(thread: false) == 512, "frames per callback of each start")
expect(AudioOutputSize.rate(thread: true) == 48000 && AudioOutputSize.rate(thread: true, wireless: true) == 44100
       && AudioOutputSize.rate(thread: false) == 44100, "QEMU's rate of each start (SDL3 opens the queue at it)")
expect(AudioOutputSize.frames(thread: true, minimum: 0) == 256 && AudioOutputSize.frames(thread: true, minimum: 512) == 512,
       "own thread started wired: 256, 512 after a switch to AirPods")
expect(AudioOutputSize.frames(thread: false, minimum: 512) == 512 && AudioOutputSize.frames(thread: true, wireless: true, minimum: 0) == 512,
       "main loop and wireless start: 512 either way")
// SDL3's queue: 6 x 256 frames at 48 kHz (32 ms), 4 x 512 (42.7 ms), 3 x 1024 (64 ms); 4 x 512 at 44.1 kHz (46.4 ms).
expect(near(AudioOutputSize.queueMs(frames: 256), 32.0) && near(AudioOutputSize.queueMs(frames: 512), 42.67)
       && near(AudioOutputSize.queueMs(frames: 1024), 64.0) && near(AudioOutputSize.queueMs(frames: 512, rate: 44100), 46.44),
       "SDL3's AudioQueue length per size and rate")
// A/V sync: the queue and ring the start or a switch gave are part of QEMU's delay.
expect(AudioDelay.qemuPart(thread: true, outFrames: 256) == AudioDelay.qemuThreadMs, "own thread, 256 frames: its QEMU part")
expect(AudioDelay.qemuPart(thread: true, outFrames: 512) == AudioDelay.qemuThreadMs + 11, "own thread switched to AirPods: 11 ms more (the queue)")
expect(AudioDelay.qemuPart(thread: false, outFrames: 512) == AudioDelay.qemuMs, "main loop: 512 is its own size")
expect(AudioDelay.qemuThreadWirelessMs == 62, "own thread started with AirPods: ring and queue of 46 ms each, 62 ms estimated")
expect(AudioDelay.qemuPart(thread: true, wireless: true, outFrames: 512) == AudioDelay.qemuThreadWirelessMs,
       "own thread started with AirPods: its own QEMU part")
expect(AudioDelay.qemuThreadMs < AudioDelay.qemuThreadWirelessMs && AudioDelay.qemuThreadWirelessMs < AudioDelay.qemuMs,
       "own thread with AirPods: between the own thread's and the main loop's")
expect(AudioDelay.total(deviceMs: airpods.ms, thread: true, wireless: true, outFrames: 512) == AudioDelay.qemuThreadWirelessMs + 171,
       "own thread with AirPods: QEMU + the device")

// The user's correction, and the limits.
expect(AudioDelay.total(deviceMs: 10, extraMs: -40) == AudioDelay.qemuMs - 30, "a negative correction")
expect(AudioDelay.total(deviceMs: nil, extraMs: -5000) == 0, "never below 0")
expect(AudioDelay.total(deviceMs: 900, extraMs: 900) == 1000, "never above 1 s")

// What CoreAudio can get wrong.
expect(AudioDelay.Device(latency: 100, safetyOffset: 0, streamLatency: 0, bufferFrames: 512, sampleRate: 0).ms == nil, "no rate: unknown")
expect(AudioDelay.Device(latency: UInt32.max, safetyOffset: UInt32.max, streamLatency: 0, bufferFrames: 0, sampleRate: 48000).ms == nil,
       "over 1 s: unknown (no overflow)")

// Every measured run in lip-sync tolerance with QEMU's part: the sound at
// most 15 ms early and 45 ms late.
for d in AudioDelay.measuredQemuMs {
    let off = d - Double(AudioDelay.qemuMs)
    expect(off >= -15 && off <= 45, "measured \(Int(d)) ms: sound \(Int(off)) ms after the picture")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
