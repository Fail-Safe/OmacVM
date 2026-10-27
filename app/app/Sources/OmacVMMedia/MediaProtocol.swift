import Foundation

/// AirPods and media controls (docs/adr/0058-now-playing.md): the virtio port
/// between OmacVM.app's launcher and the VM's agent omacvm-media
/// (src/app/guest/omacvm-media), one JSON object per line, "t" says what.
///
/// From the VM:
///   {"t":"hello","v":1,"n":"5f2c9a01"}   the agent started (n: this run's id);
///                                        again every 5 s until the Mac answers
///   {"t":"state","s":"playing","player":"Chromium","title":"..","artist":"..",
///    "album":"..","len":213.5,"pos":12.0,"rate":1.0,"next":true,"prev":false}
///                                        what its player does (s: playing,
///                                        paused, stopped, none): after the
///                                        Mac's hello, on every change, every
///                                        15 s while it has a player
/// To the VM:
///   {"t":"hello","v":1,"on":true,"n":"5f2c9a01"}  the answer, with the agent's
///                                        n (the agent takes only that one, so
///                                        nothing left in the port from before
///                                        counts); again when the switch changes
///                                        and after the Mac wakes. Without n: "say
///                                        hello again" (a line came before any
///                                        hello on this connection)
///   {"t":"cmd","c":"play|pause|next|previous"}
///
/// Both sides ignore what they do not know (t, keys, commands); the lower v
/// counts. The guest is untrusted: a line is at most 4 KB and 20 a second, its
/// text is cut to 200 characters (the player's name to 64) without control or
/// direction characters, its numbers kept in range, nothing counts before its
/// hello, and no picture comes from it.
public enum MediaPort {
    public static let name = "org.omacvm.media"
    /// After mac-ime's 8; a port on vser0 moves no PCI device.
    public static let number = 9
    public static let version = 1

    /// QEMU's arguments; `socket` as QEMU wants it (commas doubled).
    public static func arguments(socket: String) -> [String] {
        ["-chardev", "socket,id=media0,path=\(socket),server=on,wait=off",
         "-device", "virtserialport,bus=vser0.0,nr=\(number),chardev=media0,name=\(name)"]
    }
}

public enum MediaLimits {
    public static let lineBytes = 4096
    public static let linesPerSecond = 20
    public static let text = 200
    public static let player = 64
    /// The guest's run id in its hello.
    public static let id = 32
    public static let longest = 86_400.0
    public static let fastest = 4.0
    /// JSON nesting: our lines have one object; deeper ones are not parsed.
    public static let depth = 4
}

/// The app-wide switch "AirPods and media controls" (org.omacvm.app
/// mediaControls). On by default; off by default for the test identity, so a
/// test VM that plays never takes the person's AirPods.
public enum MediaControls {
    public static let key = "mediaControls"
    public static func defaultOn(testIdentity: Bool) -> Bool { !testIdentity }
}

/// What the guest's player does, as the Mac reads it.
public struct GuestState: Equatable, Sendable {
    public enum Status: String, Sendable { case playing, paused, stopped, none }
    public var status: Status
    public var player = ""
    public var title = ""
    public var artist = ""
    public var album = ""
    public var length: Double?
    public var position: Double?
    public var rate = 1.0
    public var canNext = false
    public var canPrevious = false

    public init(status: Status, player: String = "", title: String = "", artist: String = "", album: String = "",
                length: Double? = nil, position: Double? = nil, rate: Double = 1.0,
                canNext: Bool = false, canPrevious: Bool = false) {
        self.status = status; self.player = player; self.title = title; self.artist = artist; self.album = album
        self.length = length; self.position = position; self.rate = rate
        self.canNext = canNext; self.canPrevious = canPrevious
    }
}

public enum GuestMessage: Equatable, Sendable {
    case hello(version: Int, id: String)
    case state(GuestState)
}

/// What the Mac sends the VM's player. Never a toggle: AirPods pause when one
/// comes out, and a toggle would start a paused video.
public enum MacCommand: String, CaseIterable, Sendable { case play, pause, next, previous }

public enum MediaLine {
    /// One line from the guest (without its newline); nil for anything we do
    /// not take.
    public static func parse(_ line: Data) -> GuestMessage? {
        guard line.count <= MediaLimits.lineBytes, shallow(line),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = o["t"] as? String else { return nil }
        switch t {
        case "hello":
            guard let v = integer(o["v"]), v >= 1 else { return nil }
            let id = clean(o["n"], limit: MediaLimits.id)
            return .hello(version: v, id: id)
        case "state":
            guard let raw = o["s"] as? String, let status = GuestState.Status(rawValue: raw) else { return nil }
            var s = GuestState(status: status)
            s.player = clean(o["player"], limit: MediaLimits.player)
            s.title = clean(o["title"], limit: MediaLimits.text)
            s.artist = clean(o["artist"], limit: MediaLimits.text)
            s.album = clean(o["album"], limit: MediaLimits.text)
            s.length = number(o["len"], in: 0...MediaLimits.longest).flatMap { $0 > 0 ? $0 : nil }
            s.position = number(o["pos"], in: 0...MediaLimits.longest).map { min($0, s.length ?? $0) }
            s.rate = number(o["rate"], in: 0...MediaLimits.fastest) ?? 1.0
            s.canNext = flag(o["next"])
            s.canPrevious = flag(o["prev"])
            return .state(s)
        default:
            return nil
        }
    }

    public static func hello(on: Bool, id: String?) -> Data {
        var o: [String: Any] = ["t": "hello", "v": MediaPort.version, "on": on]
        if let id { o["n"] = id }
        return encode(o)
    }

    public static func command(_ c: MacCommand) -> Data { encode(["t": "cmd", "c": c.rawValue]) }

    static func encode(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    /// The guest's text as the Mac shows it: a string cut to `limit`
    /// characters (Unicode scalars), without control, line break or direction
    /// characters; anything else is "".
    public static func clean(_ v: Any?, limit: Int) -> String {
        guard let s = v as? String else { return "" }
        var out = String.UnicodeScalarView()
        var n = 0
        for u in s.unicodeScalars where !hidden(u) {
            if n == limit { break }
            out.append(u)
            n += 1
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    static func hidden(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F: return true   // control characters
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true   // text direction
        case 0x2028, 0x2029: return true   // line and paragraph breaks
        default: return false
        }
    }

    /// At most MediaLimits.depth objects or arrays inside each other (strings
    /// skipped), so a crafted line never makes the parser go deep.
    static func shallow(_ line: Data) -> Bool {
        var depth = 0, inString = false, escaped = false
        for b in line {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > MediaLimits.depth { return false }
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return true
    }

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func flag(_ v: Any?) -> Bool { isBool(v) && (v as? Bool) == true }

    static func integer(_ v: Any?) -> Int? {
        guard !isBool(v), let n = v as? NSNumber, let d = Double(exactly: n.doubleValue), d.isFinite,
              d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func number(_ v: Any?, in range: ClosedRange<Double>) -> Double? {
        guard !isBool(v), let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return min(max(d, range.lowerBound), range.upperBound)
    }
}

/// Cuts the port's bytes into lines: at most 4 KB each (a longer one is
/// dropped up to its newline), at most 20 a second (more are dropped).
public struct MediaLines {
    private var buffer = [UInt8]()
    private var skipping = false
    private var second = -Double.infinity
    private var inSecond = 0
    public private(set) var droppedLong = 0
    public private(set) var droppedFast = 0

    public init() {}

    public mutating func feed<C: Collection>(_ bytes: C, now: Double) -> [Data] where C.Element == UInt8 {
        var lines: [Data] = []
        for b in bytes {
            if b == 0x0A {
                if skipping {
                    skipping = false
                } else if take(now: now) {
                    lines.append(Data(buffer))
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            guard !skipping else { continue }
            if buffer.count == MediaLimits.lineBytes {
                buffer.removeAll(keepingCapacity: true)
                skipping = true
                droppedLong += 1
                continue
            }
            buffer.append(b)
        }
        return lines
    }

    private mutating func take(now: Double) -> Bool {
        if now - second >= 1 { second = now; inSecond = 0 }
        guard inSecond < MediaLimits.linesPerSecond else { droppedFast += 1; return false }
        inSecond += 1
        return true
    }
}
