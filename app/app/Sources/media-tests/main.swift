// AirPods and media controls (OmacVMMedia), without a VM or macOS's Now Playing:
//   cd app/app && swift run media-tests
// The port's lines (caps, what the guest may send, a seeded fuzz), the claim's
// rules (when the VM is Now Playing, the waits, giving up, an agent that
// starts again), the switch's default. Exit 0 when all pass. CI runs it.
import Foundation
import OmacVMMedia

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
func json(_ s: String) -> Data { Data(s.utf8) }
func state(_ s: String) -> GuestState? {
    if case .state(let st)? = MediaLine.parse(json(s)) { return st }
    return nil
}
func object(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d.dropLast()) as? [String: Any]) ?? [:]
}

// MARK: The port

let args = MediaPort.arguments(socket: "/tmp/x/ab,,c.media")
expect(args == ["-chardev", "socket,id=media0,path=/tmp/x/ab,,c.media,server=on,wait=off",
                "-device", "virtserialport,bus=vser0.0,nr=9,chardev=media0,name=org.omacvm.media"],
       "port: chardev and virtserialport nr 9 named org.omacvm.media")
expect(!(0...8).contains(MediaPort.number), "port: nr 9 is after the app's ports 0-8 (console .. mac-ime)")
expect(MediaControls.key == "mediaControls", "switch: key mediaControls")
expect(MediaControls.defaultOn(testIdentity: false), "switch: on by default for the app")
expect(!MediaControls.defaultOn(testIdentity: true), "switch: off by default for the test identity (a test VM never takes the person's AirPods)")

// MARK: Lines from the guest: what is taken

expect(MediaLine.parse(json(#"{"t":"hello","v":1,"n":"5f2c9a01"}"#)) == .hello(version: 1, id: "5f2c9a01"), "hello with its id")
expect(MediaLine.parse(json(#"{"t":"hello","v":2,"n":"x","can":["play"],"new":{"a":1}}"#)) == .hello(version: 2, id: "x"),
       "hello: a newer agent's keys are ignored")
expect(MediaLine.parse(json(#"{"t":"hello","n":"x"}"#)) == nil, "hello without v: not taken")
expect(MediaLine.parse(json(#"{"t":"hello","v":0}"#)) == nil, "hello v 0: not taken")
expect(MediaLine.parse(json(#"{"t":"hello","v":true}"#)) == nil, "hello v true: not a number")
expect(MediaLine.parse(json(#"{"t":"hello","v":1.5}"#)) == nil, "hello v 1.5: not taken")
expect(MediaLine.parse(json(#"{"t":"hello","v":1}"#)) == .hello(version: 1, id: ""), "hello without n: an empty id")
let full = state(#"{"t":"state","s":"playing","player":"Chromium","title":"Song","artist":"Band","album":"LP","len":213.5,"pos":12,"rate":1,"next":true,"prev":false}"#)
expect(full == GuestState(status: .playing, player: "Chromium", title: "Song", artist: "Band", album: "LP",
                          length: 213.5, position: 12, rate: 1, canNext: true, canPrevious: false), "state: every field")
for s in ["playing", "paused", "stopped", "none"] {
    expect(state(#"{"t":"state","s":"\#(s)"}"#)?.status.rawValue == s, "state \(s)")
}
expect(state(#"{"t":"state","s":"Playing"}"#) == nil, "state: unknown s not taken")
expect(state(#"{"t":"state"}"#) == nil, "state: no s, not taken")
expect(MediaLine.parse(json(#"{"t":"bye"}"#)) == nil, "unknown t ignored")
expect(MediaLine.parse(json(#"{"s":"playing"}"#)) == nil, "no t ignored")
expect(MediaLine.parse(json(#"[1,2]"#)) == nil, "not an object")
expect(MediaLine.parse(json(#"{"t":"state","s":"playing""#)) == nil, "cut JSON")
expect(MediaLine.parse(json("")) == nil, "empty line")
expect(MediaLine.parse(Data([0xFF, 0xFE, 0x7B])) == nil, "not UTF-8")
expect(MediaLine.parse(json(#"{"t":"state","s":"playing","x":[[[[[[1]]]]]]}"#)) == nil, "nested deeper than 4: not parsed")
expect(state(#"{"t":"state","s":"playing","title":"[[[[[[{{{{{"}"#)?.title == "[[[[[[{{{{{", "brackets inside a string are text")
expect(state(#"{"t":"state","s":"playing","title":"a\"[[[[[["}"#)?.title == "a\"[[[[[[", "an escaped quote keeps the string open")

// Wrong types, numbers out of range.
let odd = state(#"{"t":"state","s":"paused","player":5,"title":["x"],"artist":null,"len":"3","pos":true,"rate":"1","next":1,"prev":"true"}"#)
expect(odd == GuestState(status: .paused), "wrong types: empty, no numbers, flags false")
expect(state(#"{"t":"state","s":"playing","len":1e300,"pos":-5,"rate":99}"#).map { [$0.length, $0.position, $0.rate] }
       == [86_400, 0, 4], "numbers clamped: len to a day, pos to 0, rate to 4")
expect(state(#"{"t":"state","s":"playing","len":100,"pos":500}"#)?.position == 100, "pos at most len")
expect(state(#"{"t":"state","s":"playing","len":0}"#)?.length == nil, "len 0: unknown")
expect(state(#"{"t":"state","s":"playing","rate":-1}"#)?.rate == 0, "rate below 0: 0")

// Text: caps, control and direction characters.
let long = String(repeating: "a", count: 500)
let capped = state(#"{"t":"state","s":"playing","player":"\#(long)","title":"\#(long)"}"#)
expect(capped?.player.count == 64 && capped?.title.count == 200, "text cut (player 64, title 200), the line still taken")
expect(state(#"{"t":"state","s":"playing","title":"a\u0000b\u001bc\u007fd\u0085e\nf\tg"}"#)?.title == "abcdefg", "control characters dropped")
expect(state(#"{"t":"state","s":"playing","title":"x\u202eevil\u202c\u2066y\u2069\u200f\u061cz"}"#)?.title == "xevilyz",
       "direction characters dropped")
expect(state(#"{"t":"state","s":"playing","title":"a\u2028b\u2029c"}"#)?.title == "abc", "line and paragraph breaks dropped")
expect(state(#"{"t":"state","s":"playing","title":"  padded  "}"#)?.title == "padded", "spaces at the ends trimmed")
let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
expect(state(#"{"t":"state","s":"playing","title":"\#(family) ok"}"#)?.title == "\(family) ok", "joined emoji kept")

// The biggest state the agent sends (src/app/guest/omacvm-media: fields cut first,
// ensure_ascii=False) fits one line: 200 four-byte emoji in each text field.
let emoji = String(repeating: "😀", count: 200)
let biggest: [String: Any] = ["t": "state", "s": "playing", "player": String(repeating: "😀", count: 64),
                              "title": emoji, "artist": emoji, "album": emoji, "len": 86_399.999, "pos": 86_399.999,
                              "rate": 1.0, "next": true, "prev": true]
let biggestLine = try! JSONSerialization.data(withJSONObject: biggest)
expect(biggestLine.count + 1 <= MediaLimits.lineBytes, "the biggest state is \(biggestLine.count + 1) bytes, within 4 KB")
expect(state(String(decoding: biggestLine, as: UTF8.self))?.title == emoji, "and it is taken whole")
// The same as Python's default ensure_ascii=True writes it (😀, 12 bytes each): over 4 KB.
let escaped = String(decoding: biggestLine, as: UTF8.self).replacingOccurrences(of: "😀", with: "\\ud83d\\ude00")
expect(escaped.utf8.count > MediaLimits.lineBytes, "escaped emoji would be \(escaped.utf8.count) bytes: why the agent writes UTF-8")

// MARK: Lines: 4 KB, 20 a second

var lines = MediaLines()
var got = lines.feed(Array("{\"a\":1}\n{\"b\"".utf8), now: 0)
expect(got == [json(#"{"a":1}"#)], "a whole line out, the rest kept")
got = lines.feed(Array(":2}\n".utf8), now: 0)
expect(got == [json(#"{"b":2}"#)], "the rest completed by the next read")
got = lines.feed(Array(repeating: UInt8(ascii: "x"), count: 5000) + Array("\nok\n".utf8), now: 0)
expect(got == [json("ok")] && lines.droppedLong == 1, "a line over 4 KB dropped up to its newline, the next one taken")
got = lines.feed(Array(repeating: UInt8(ascii: "x"), count: 4096) + Array("\n".utf8), now: 0)
expect(got.count == 1 && got[0].count == 4096, "exactly 4 KB taken")
var fast = MediaLines()
got = fast.feed(Array(String(repeating: "x\n", count: 50).utf8), now: 10)
expect(got.count == 20 && fast.droppedFast == 30, "50 lines in one second: 20 taken, 30 dropped")
got = fast.feed(Array("y\n".utf8), now: 10.5)
expect(got.isEmpty, "still the same second: dropped")
got = fast.feed(Array("z\n".utf8), now: 11)
expect(got == [json("z")], "the next second: taken again")

// MARK: Lines to the guest

let hello = object(MediaLine.hello(on: true, id: "5f2c9a01"))
expect(hello["t"] as? String == "hello" && hello["v"] as? Int == 1 && hello["on"] as? Bool == true && hello["n"] as? String == "5f2c9a01",
       "the Mac's hello: v 1, on, the agent's n")
expect(object(MediaLine.hello(on: false, id: nil))["n"] == nil, "a hello without n (say hello again)")
expect(MediaLine.hello(on: true, id: "x").last == 0x0A, "lines end in a newline")
for c in MacCommand.allCases {
    let o = object(MediaLine.command(c))
    expect(o["t"] as? String == "cmd" && o["c"] as? String == c.rawValue, "command \(c.rawValue)")
}
expect(!MacCommand.allCases.map(\.rawValue).contains { $0.lowercased().contains("toggle") }, "no toggle is ever sent to the VM")

// MARK: The claim

let playing = GuestState(status: .playing, player: "mpv", title: "SECRET-TITLE", artist: "SECRET-ARTIST", album: "A",
                         length: 60, position: 5, rate: 1, canNext: true, canPrevious: false)
var paused = playing; paused.status = .paused
var stopped = playing; stopped.status = .stopped
let none = GuestState(status: .none)
var logs: [String] = []
var sent: [Data] = []
func run(_ fx: [MediaClaim.Effect]) {
    for e in fx {
        switch e {
        case .log(let l): logs.append(l)
        case .send(let d): sent.append(d)
        }
    }
}
/// A claim with a connection and the agent's hello at `t`.
func linked(on: Bool = true, t: Double = 0) -> MediaClaim {
    var c = MediaClaim(on: on)
    c.connected()
    run(c.received(.hello(version: 1, id: "g1"), now: t))
    return c
}

var c = MediaClaim(on: true)
c.connected()
run(c.received(.state(playing), now: 0))
expect(!c.claimed, "a state before the agent's hello: no claim")
expect(sent.count == 1 && object(sent[0])["n"] == nil, "  the Mac asks for a hello (once)")
run(c.received(.state(playing), now: 0.1))
expect(sent.count == 1, "  only once per connection")
sent = []
run(c.received(.hello(version: 1, id: "g1"), now: 1))
expect(sent.count == 1 && object(sent[0])["n"] as? String == "g1" && object(sent[0])["on"] as? Bool == true,
       "the agent's hello is answered with its n and the switch")
expect(logs.contains("the VM's agent is there (v1)"), "  qemu.log says the agent is there")
logs = []
run(c.received(.hello(version: 1, id: "g1"), now: 6))
expect(logs.isEmpty && sent.count == 2, "the same agent's hello again (its answer was lost): answered, said once")
expect(!c.claimed && c.shown == nil, "hello alone: no claim")

c = linked()
run(c.received(.state(paused), now: 1))
expect(!c.claimed, "a paused player alone never claims")
run(c.received(.state(stopped), now: 2)); run(c.received(.state(none), now: 3))
expect(!c.claimed, "stopped or no player: no claim")
run(c.received(.state(playing), now: 4))
expect(c.claimed && c.shown?.playing == true, "the VM's player plays: claimed, playing")
expect(c.shown?.title == "SECRET-TITLE" && c.shown?.artist == "SECRET-ARTIST" && c.shown?.duration == 60
       && c.shown?.elapsed == 5 && c.shown?.rate == 1 && c.shown?.canNext == true && c.shown?.canPrevious == false,
       "  Now Playing: title, artist, length, position, rate, next yes, previous no")
expect(logs.contains("Now Playing is the VM (mpv playing)"), "  qemu.log: the claim with the player's name")

var off = MediaClaim(on: false)
off.connected()
run(off.received(.hello(version: 1, id: "g"), now: 0))
run(off.received(.state(playing), now: 1))
expect(!off.claimed, "switch off: no claim while playing")
var noTitle = playing; noTitle.title = ""
c = linked(); run(c.received(.state(noTitle), now: 1))
expect(c.shown?.title == "mpv", "no title: the player's name")

// Paused: kept, shown paused after 1.5 s; short dips leave it alone.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.state(paused), now: 20))
expect(c.claimed && c.shown?.playing == true, "paused 0 s: Now Playing still playing (a track change passes through)")
expect(c.deadline == 21.5, "  due at 21.5")
run(c.tick(now: 21.0))
expect(c.shown?.playing == true, "paused 1 s: still playing")
run(c.received(.state(playing), now: 21.2))
run(c.tick(now: 23))
expect(c.shown?.playing == true, "back to playing within 1.5 s: never shown paused")
run(c.received(.state(paused), now: 30)); run(c.tick(now: 31.5))
expect(c.claimed && c.shown?.playing == false && c.shown?.rate == 0, "paused 1.5 s: kept, shown paused, rate 0")
run(c.received(.state(stopped), now: 40)); run(c.tick(now: 42.9))
expect(c.claimed, "stopped 2.9 s: kept")
run(c.tick(now: 43))
expect(!c.claimed && c.shown == nil, "stopped 3 s: given up")
expect(logs.last == "Now Playing given up (nothing plays in the VM)", "  qemu.log says why")
c = linked(); run(c.received(.state(playing), now: 0)); run(c.received(.state(none), now: 5))
expect(c.shown?.title == "SECRET-TITLE", "no player for a moment: Now Playing keeps the last text")
run(c.received(.state(playing), now: 6)); run(c.tick(now: 10))
expect(c.claimed, "a player again within 3 s: kept")
run(c.received(.state(none), now: 11)); run(c.tick(now: 14))
expect(!c.claimed, "no player 3 s: given up")

// Paused, then playing again: takes Now Playing back (macOS's rule), at most once per 10 s.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.state(paused), now: 100)); run(c.tick(now: 102))
run(c.received(.state(playing), now: 110))
expect(c.shown?.playing == true, "paused, then playing: shown playing at once (Now Playing taken back)")
run(c.received(.state(paused), now: 112)); run(c.tick(now: 114))
run(c.received(.state(playing), now: 115))
expect(c.shown?.playing == false && c.deadline == 120, "playing again 5 s after the last take: waits until 10 s")
run(c.tick(now: 120))
expect(c.shown?.playing == true, "  then taken")
// A flapping player cannot keep taking the controls from a Mac app.
var takes = 0
var flap = linked(); run(flap.received(.state(playing), now: 0))
var shownBefore = flap.shown?.playing ?? false
var t = 0.0
while t < 60 {
    t += 2
    run(flap.received(.state(t.truncatingRemainder(dividingBy: 4) == 0 ? playing : paused), now: t))
    run(flap.tick(now: t + 1.9))
    let now = flap.shown?.playing ?? false
    if now && !shownBefore { takes += 1 }
    shownBefore = now
}
expect(takes <= 6, "a player flapping every 2 s for a minute takes Now Playing \(takes) times (at most 6)")
// Giving up and claiming again counts too: a player that stops 3 s or more
// between plays (an autoplay countdown) cannot take the controls more often.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.state(stopped), now: 1)); run(c.tick(now: 4))
expect(!c.claimed, "stopped 3 s after a claim at 0: given up")
run(c.received(.state(playing), now: 6))
expect(!c.claimed && c.deadline == 10, "playing again at 6 s: the new claim waits until 10 s after the last")
run(c.tick(now: 10))
expect(c.claimed && c.shown?.playing == true, "  then claimed, playing")
c = linked(); run(c.received(.state(playing), now: 0)); run(c.received(.state(stopped), now: 1)); run(c.tick(now: 4))
run(c.received(.state(playing), now: 6)); run(c.received(.state(paused), now: 7)); run(c.tick(now: 10))
expect(!c.claimed && c.deadline == nil, "  paused before then: no claim, nothing waits")
c = linked(); run(c.received(.state(playing), now: 0)); run(c.received(.state(stopped), now: 1)); run(c.tick(now: 4))
run(c.received(.state(playing), now: 6)); c.disconnected(); run(c.tick(now: 10))
expect(!c.claimed && c.deadline == nil, "  the connection gone before then: no claim from the old state")
c = linked(); run(c.received(.state(playing), now: 0)); run(c.received(.state(stopped), now: 100)); run(c.tick(now: 103))
run(c.received(.state(playing), now: 105))
expect(c.claimed, "the next video 105 s after the last take: claimed at once")
var claims: [Double] = []
var cycle = linked()
t = 0
while t < 60 {   // plays 1 s, stops 5 s (given up after 3 s), again and again
    let was = cycle.claimed
    switch t.truncatingRemainder(dividingBy: 6) {
    case 0: run(cycle.received(.state(playing), now: t))
    case 1: run(cycle.received(.state(stopped), now: t))
    default: break
    }
    run(cycle.tick(now: t))
    if cycle.claimed && !was { claims.append(t) }
    t += 0.5
}
let gaps = zip(claims.dropFirst(), claims).map { $0 - $1 }
expect(claims.count <= 6 && gaps.allSatisfy { $0 >= 10 },
       "a player that plays 1 s and stops 5 s for a minute claims \(claims.count) times, at least 10 s apart")
// A playlist moving on while a Mac app plays: the dip is shorter than 1.5 s, so no take.
c = linked(); run(c.received(.state(playing), now: 0))
let before = c.shown?.playing
run(c.received(.state(stopped), now: 50)); run(c.received(.state(playing), now: 50.4)); run(c.tick(now: 52))
expect(before == true && c.shown?.playing == true, "a track change (stopped 0.4 s): Now Playing never left playing, nothing taken")

// Commands: only while claimed, from the agent's own last state.
c = linked(); run(c.received(.state(paused), now: 0))
expect(c.command(.play, now: 0) == .notClaimed, "a command before any claim: not ours")
run(c.received(.state(playing), now: 1))
expect(c.command(.togglePlayPause, now: 1) == .send(.pause), "toggle while playing: pause")
expect(c.command(.pause, now: 1) == .send(.pause) && c.command(.play, now: 1) == .send(.play), "pause and play as they are")
expect(c.command(.stop, now: 1) == .send(.pause), "stop (both AirPods out): pause, the claim stays")
expect(c.command(.nextTrack, now: 1) == .send(.next) && c.command(.previousTrack, now: 1) == .send(.previous), "next and previous")
run(c.commandSent(.togglePlayPause, .pause, now: 2))
expect(c.shown?.playing == false, "after the Mac's pause: shown paused at once")
expect(logs.last == "togglePlayPause from macOS: pause to the VM's player", "  qemu.log names the command")
run(c.received(.state(playing), now: 2.1))
expect(c.shown?.playing == false, "  a state from before the pause does not flip it back")
run(c.received(.state(paused), now: 2.3)); run(c.tick(now: 4))
expect(c.shown?.playing == false && c.claimed, "  the agent's paused confirms it, claim kept")
run(c.received(.state(paused), now: 2.5))
run(c.tick(now: 3))
expect(c.command(.togglePlayPause, now: 4) == .send(.play), "toggle while the agent says paused: play")
// Toggle follows the agent, not what Now Playing shows (paused 1 s, still shown playing).
c = linked(); run(c.received(.state(playing), now: 0)); run(c.received(.state(paused), now: 10))
expect(c.shown?.playing == true && c.command(.togglePlayPause, now: 10) == .send(.play), "toggle uses the agent's paused, not the shown playing")
run(c.commandSent(.play, .play, now: 10.5))
expect(c.shown?.playing == true, "after the Mac's play: shown playing")
run(c.tick(now: 12.1))
expect(c.shown?.playing == false, "  the player stayed paused 1.5 s: shown paused again")
// A quick double press: the second toggle comes before the agent's paused.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.commandSent(.togglePlayPause, .pause, now: 20))
expect(c.command(.togglePlayPause, now: 20.2) == .send(.play), "a second toggle 0.2 s after the Mac's pause, the agent still says playing: play")
run(c.commandSent(.togglePlayPause, .play, now: 20.2))
expect(c.command(.togglePlayPause, now: 20.4) == .send(.pause), "  a third: pause")
expect(c.command(.togglePlayPause, now: 22) == .send(.pause), "  the hold over: from the agent's state again (playing): pause")
c = linked(); run(c.received(.state(playing), now: 0))
c.disconnected()
expect(c.command(.pause, now: 1) == .noLink && c.claimed, "connection gone: commands fail, the claim waits for the lease")

// The agent: lease, an agent that starts again, the Mac's sleep.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.state(playing), now: 15)); run(c.tick(now: 59))
expect(c.claimed, "a state every 15 s: kept")
expect(c.deadline == 60, "  the lease is due 45 s after the last line")
run(c.tick(now: 60))
expect(!c.claimed && logs.last == "Now Playing given up (no word from the VM's agent for 45 s)", "nothing for 45 s: given up")
for (st, name) in [(playing, "playing"), (paused, "paused")] {
    c = linked(); run(c.received(.state(playing), now: 0))
    if st.status == .paused { run(c.received(.state(paused), now: 5)); run(c.tick(now: 7)) }
    let shown = c.shown?.playing
    logs = []
    run(c.received(.hello(version: 1, id: "g2"), now: 10))   // omacvm apply restarts the agent
    expect(c.claimed, "apply while \(name): the new agent's hello keeps the claim")
    run(c.received(.state(st), now: 11)); run(c.tick(now: 20))
    expect(c.claimed && c.shown?.playing == shown, "  its first state (\(name)) within 3 s: the same claim, Now Playing as it was")
    expect(!logs.contains { $0.hasPrefix("Now Playing") }, "  never given up and taken again")
}
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.hello(version: 1, id: "g2"), now: 10)); run(c.tick(now: 13))
expect(!c.claimed, "a new agent that names no player within 3 s: given up")
c = linked(); run(c.received(.state(playing), now: 0))
run(c.received(.hello(version: 1, id: "g2"), now: 10)); run(c.received(.state(none), now: 11)); run(c.tick(now: 14))
expect(!c.claimed, "a new agent with no player: given up after 3 s")
c = linked(); run(c.received(.state(playing), now: 0))
c.sleep(); run(c.tick(now: 500))
expect(c.claimed && c.deadline == nil, "the Mac asleep: the claim stays, the lease waits")
sent = []
run(c.wake(now: 500))
expect(sent.count == 1 && object(sent[0])["n"] as? String == "g1", "the Mac woke: its hello asks the agent for a fresh state")
run(c.tick(now: 544))
expect(c.claimed, "  the lease starts again at the wake")
run(c.tick(now: 545))
expect(!c.claimed, "  a VM that did not wake: given up 45 s later")
c = linked(); run(c.received(.state(playing), now: 0))
t = 1
while t < 1800 { run(c.received(.state(paused), now: t)); t += 15 }   // the agent's 15 s states
run(c.tick(now: 1800.9))
expect(c.claimed, "paused 30 min less a moment: kept")
run(c.tick(now: 1801))
expect(!c.claimed && logs.last == "Now Playing given up (paused for 30 minutes)", "paused 30 min: given up")
run(c.received(.state(paused), now: 1802))
expect(!c.claimed, "  still paused: not taken again")
run(c.received(.state(playing), now: 1803))
expect(c.claimed, "  playing again: claimed again")

// The switch, live.
c = linked(); run(c.received(.state(playing), now: 0))
sent = []
run(c.switched(false, now: 5))
expect(!c.claimed && sent.count == 1 && object(sent[0])["on"] as? Bool == false, "switched off: given up, the agent told off")
expect(logs.suffix(2) == ["off (switched while the VM runs)", "Now Playing given up (the app's switch is off)"], "  qemu.log says both")
run(c.received(.state(playing), now: 6))
expect(!c.claimed, "  states while off: no claim")
sent = []
run(c.switched(true, now: 7))
expect(!c.claimed && sent.count == 1 && object(sent[0])["on"] as? Bool == true, "switched on: the agent told, no claim from an old state")
run(c.received(.state(playing), now: 7.2))
expect(c.claimed, "  the agent's fresh state, 7 s after the last take: claimed at once (the person's switch does not wait)")
var quiet = MediaClaim(on: true)
sent = []
run(quiet.switched(false, now: 0))
expect(sent.isEmpty, "switched with no agent there: nothing written (a VM without the agent never gets a line)")

// QEMU ends.
c = linked(); run(c.received(.state(playing), now: 0))
run(c.stop("the VM stopped"))
expect(!c.claimed && c.shown == nil && logs.last == "Now Playing given up (the VM stopped)", "QEMU ended: given up at once")
expect(c.command(.play, now: 1) == .notClaimed, "  and no commands after")

// Titles never go into qemu.log.
expect(!logs.contains { $0.contains("SECRET") }, "no title or artist in any qemu.log line (\(logs.count) lines)")

// Now Playing's info is set again only when something changed.
let a = MediaClaim.Shown(title: "t", artist: "", album: "", duration: 100, elapsed: 10, playing: true, rate: 1,
                         canNext: false, canPrevious: false)
var b = a; b.elapsed = 25
expect(!b.needsInfo(after: a, seconds: 15), "15 s later at 25 s while playing: no new info")
b.elapsed = 40
expect(b.needsInfo(after: a, seconds: 15), "a seek (40 s instead of 25): new info")
b = a; b.title = "u"
expect(b.needsInfo(after: a, seconds: 0), "a new title: new info")
b = a; b.playing = false; b.rate = 0
expect(b.needsInfo(after: a, seconds: 0), "paused: new info")
expect(a.needsInfo(after: nil, seconds: 0), "nothing set yet: info")
// Compared with the info last set, not the last shown: a seek right after a
// lease that set nothing still sets it, and the leases alone set it once.
func at(_ e: Double) -> MediaClaim.Shown { var s = a; s.elapsed = e; return s }
var gate = MediaClaim.InfoGate()
expect(gate.needsSet(at(10), now: 0), "info: the first is set")
expect(!gate.needsSet(at(25), now: 15), "  15 s later at 25 s: not set again")
expect(gate.needsSet(at(41), now: 16), "  a seek 15 s on, 1 s after that: set (Control Center would show 26 s)")
gate = MediaClaim.InfoGate()
var sets = 0
for i in 0...8 where gate.needsSet(at(10 + Double(i) * 15), now: Double(i) * 15) { sets += 1 }
expect(sets == 1, "  a state every 15 s while playing for 2 min: set once (\(sets))")
gate.cleared()
expect(gate.needsSet(at(130), now: 120), "  after Now Playing was given up: set again")

// MARK: Fuzz: random lines never crash, never claim before a hello, and keep every cap.

struct Rand {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
var r = Rand(s: 0x5EED_CAFE)
let seeds = [#"{"t":"hello","v":1,"n":"g"}"#,
             #"{"t":"state","s":"playing","player":"Chromium","title":"Song","artist":"Band","album":"LP","len":213.5,"pos":12.0,"rate":1.0,"next":true,"prev":false}"#,
             #"{"t":"state","s":"paused"}"#, #"{"t":"state","s":"none"}"#]
let pieces = ["\u{202e}", "\u{0}", "😀", "\"", "\\", "{", "[", "]", "}", ",", ":", "1e309", "-1", "null", "true", "\n",
              "\\u0000", "\\ud83d", "NaN", "Infinity", String(repeating: "z", count: 300)]
var fuzz = MediaClaim(on: true)
fuzz.connected()
var noHello = MediaClaim(on: true)   // gets everything but the hellos
noHello.connected()
var fuzzLines = MediaLines()
var taken = 0, bad = 0, claimedEarly = false
for i in 0..<20_000 {
    var bytes = Array(seeds[r.int(seeds.count)].utf8)
    for _ in 0..<r.int(4) {   // 0-3 changes: some lines stay whole
        switch r.int(5) {
        case 0 where !bytes.isEmpty: bytes[r.int(bytes.count)] = UInt8(r.int(256))
        case 1: bytes.insert(contentsOf: Array(pieces[r.int(pieces.count)].utf8), at: r.int(bytes.count + 1))
        case 2 where !bytes.isEmpty: bytes.removeSubrange(r.int(bytes.count)..<bytes.count)
        case 3 where bytes.count > 1: bytes.remove(at: r.int(bytes.count))
        default: bytes += Array(pieces[r.int(pieces.count)].utf8)
        }
    }
    for line in fuzzLines.feed(bytes + [0x0A], now: Double(i) * 0.06) {
        guard let m = MediaLine.parse(line) else { bad += 1; continue }
        taken += 1
        if case .state(let s) = m {
            for (text, cap) in [(s.player, 64), (s.title, 200), (s.artist, 200), (s.album, 200)] {
                if text.unicodeScalars.count > cap || text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x202A...0x202E).contains($0.value) }) {
                    expect(false, "fuzz: text over its cap or with a hidden character")
                }
            }
            if !(0...4).contains(s.rate) || (s.length.map { !(0...86_400).contains($0) } ?? false)
                || (s.position.map { !(0...86_400).contains($0) } ?? false) {
                expect(false, "fuzz: a number out of range")
            }
        }
        if case .state = m {
            run(noHello.received(m, now: Double(i) * 0.06))
            if noHello.claimed { claimedEarly = true }
        }
        run(fuzz.received(m, now: Double(i) * 0.06))
        run(fuzz.tick(now: Double(i) * 0.06))
    }
}
expect(taken > 2000 && bad > 2000, "fuzz: 20000 mutated lines, \(taken) taken, \(bad) refused, no crash")
expect(!claimedEarly, "fuzz: never claimed without a hello on the connection")
expect(!logs.contains { $0.contains("Song") || $0.contains("Band") }, "fuzz: no title in qemu.log")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
