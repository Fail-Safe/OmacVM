# 0058: AirPods and media controls: the launcher is the Mac's Now Playing app while the VM plays

Status: accepted, built (`airpods-media`), on by default: the switch "AirPods
and media controls" (`mediaControls`, the VM window's Output section; off by
default for the test identity). Notes, the spike and the reviews:
work/tracks/airpods-media.md.

## Context

AirPods and other Bluetooth headphones and speakers (AVRCP), Control Center's
and the lock screen's Now Playing, Siri and the Apple Watch send no key
events: macOS's MediaRemote hands their play, pause and skip to the Now
Playing app (`MPRemoteCommandCenter`). The VM was never that app, so they went
to the Mac (often starting Music) while a video played in the VM. The Bridge's
key tap only covers the keyboard's play keys, and only with the VM in front.

The spike on macOS 27 (mini and MacBook Air) found what makes a process Now
Playing: command targets and `playbackState = .playing` once. No sound, no
window and no Dock icon are needed. Pausing keeps it; only removing the
targets gives it up. Between processes, the last one that went into playing
wins; a paused owner keeps the controls; when the owner leaves, macOS falls
back to the next registered one. A helper process claims under its code
signing identifier, so QEMU (signed `org.omacvm.app.qemu`) would show without
a name. The app's main process shows under the app's name. No permission is
asked (tccd: nothing).

## Options

1. **QEMU** (the process with the VM's window and sound): a cocoa patch or a
   dylib. It would show as `org.omacvm.app.qemu`, needs a runtime build for
   every change, and is harder to test.
2. **The launcher** (OmacVM.app's main process, `.accessory` while the VM
   runs): Swift with unit tests, the app's name in Control Center, no
   runtime change.
3. **The Bridge**: would reach UTM, Fusion and Parallels too, but it is a
   shared optional helper with no sound and no VM of its own; a later option.

For the guest: Omarchy 4 has no `playerctl` (its upgrade removes it), and
`omarchy-shell media` has no length or position and runs a process per call.
The agent reads MPRIS on the session bus itself with Gio (python-gobject is in
Omarchy's base).

## Decision

Option 2, over a virtio port of its own:

- **Port** `org.omacvm.media` (nr 9 on vser0) on every start, whatever the
  switch, so the switch works in a running VM. JSON lines; the Mac writes
  nothing before the guest's hello (a VM without the agent never gets a line).
  The guest's hello carries a run id the Mac echoes, so nothing left in the
  port from an earlier agent counts. Both sides ignore what they do not know.
- **Guest** `omacvm-media` (user unit, `ConditionPathExists` on the port): idle
  until the Mac says on, then Gio. It reports the player that went into
  Playing last (none playing: the one that played last; at start: a paused
  one) and runs Play, Pause, Next, Previous on it. Never PlayPause: AirPods
  pause when one comes out, and a toggle would start a paused video.
- **Mac** (`OmacVMMedia`'s `MediaClaim`, `NowPlaying.swift`): claim when the
  switch is on and the guest's player plays; paused keeps the claim; a
  non-playing state under 1.5 s (a track change) changes nothing; playing
  again after a pause takes Now Playing back from a Mac app at most once per
  10 s from the VM's side; give up when nothing plays for 3 s, after 30 min
  paused, with no line for 45 s (the Mac's sleep does not count), when the
  switch goes off, and first thing when QEMU ends (the launcher outlives a
  crash, a Vulkan fallback or a lost drive). An agent that starts again
  (Update VM) keeps the claim when its first state within 3 s has a player.
- **Threads**: the rules and MediaPlayer on the main thread; the port read on
  its own thread, cut and parsed there (4 KB lines, 20 a second); writes
  never block (`MSG_DONTWAIT`, a full port drops the line: the command
  fails).
- **The guest is untrusted**: its text is cut to 200 characters (the player's
  name 64) without control or direction characters and goes only into Now
  Playing, never into qemu.log, the journal or a status file; numbers are
  clamped; no picture is taken from it. The guest cuts first and writes
  UTF-8, so its biggest line fits 4 KB (escaped emoji would not).
- Skip and seek stay off, so a double or triple press on AirPods stays next
  and previous. Volume stays the Mac's.
- On by default, as it only acts after something played in the VM, by the
  rule every Mac media app follows; off is exactly the behaviour before.
  Off by default for the test identity, so a test VM never takes the
  person's AirPods.

## Consequences

- AirPods, other Bluetooth headphones, Control Center and play keys that
  reach macOS (VM not in front, Bridge off) play, pause and skip in the VM;
  they no longer start Music while the VM holds Now Playing. With the VM in
  front and the Bridge on, the keys still go to the VM as keys only.
- A Mac app that plays and is paused while the VM keeps playing keeps the
  controls until the VM's player pauses and plays again (macOS's rule; a
  later version may read which processes play sound).
- Two players playing in the VM at once: the agent and Omarchy's keys may
  pick different ones.
- Not verified on hardware yet: real AirPods (press, double, triple, ear
  detection), other headsets, the lock screen, Siri, the Watch, macOS 15 and
  26. Tests: `swift run media-tests` (rules, a seeded fuzz),
  `src/app/guest/tests/test_omacvm_media.py` (fake MPRIS players on a private
  bus), `src/tests/media-check.sh`, `src/tests/app-settings.sh`, and the e2e
  rows in the track.
