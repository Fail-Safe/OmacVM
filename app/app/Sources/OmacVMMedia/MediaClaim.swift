import Foundation

/// The commands macOS gives the Now Playing app (MPRemoteCommandCenter) that
/// OmacVM takes. Skip and seek stay off, so a double or triple press on
/// AirPods stays next and previous.
public enum RemoteCommand: String, CaseIterable, Sendable {
    case play, pause, togglePlayPause, stop, nextTrack, previousTrack
}

/// When the launcher is the Mac's Now Playing app for the VM (docs/adr/0058).
/// Events in, what to send and log out; `shown` is what Now Playing should
/// say (nil: given up), `deadline` when `tick` is due next. No clock of its
/// own: every event brings `now` (seconds, any monotonic clock). Only the
/// main thread uses it (MediaSession).
///
/// macOS gives the controls to the last process that went into playing; a
/// paused one keeps them; removing the targets gives them up (the spike,
/// tracks/airpods-media.md). So:
/// - claim when the switch is on, the agent said hello and its player plays;
/// - paused: keep the claim (the next press resumes the VM), shown paused;
/// - a non-playing state shorter than 1.5 s (a track change, buffering)
///   leaves Now Playing as it is; playing again after a pause takes Now
///   Playing back from a Mac app, at most once per 10 s from the VM's side;
/// - give up when nothing plays for 3 s, after 30 min paused, with no word
///   from the agent for 45 s (the Mac's sleep does not count), when the
///   switch goes off or QEMU ends;
/// - an agent that starts again (apply) says hello: the claim stays if its
///   first state comes within 3 s and has a player.
public struct MediaClaim {
    public enum Effect: Equatable { case send(Data), log(String) }
    public enum Answer: Equatable { case send(MacCommand), notClaimed, noLink }

    /// What Now Playing says while claimed.
    public struct Shown: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var duration: Double?
        public var elapsed: Double?
        public var playing: Bool
        public var rate: Double
        public var canNext: Bool
        public var canPrevious: Bool

        public init(title: String, artist: String, album: String, duration: Double?, elapsed: Double?, playing: Bool,
                    rate: Double, canNext: Bool, canPrevious: Bool) {
            self.title = title; self.artist = artist; self.album = album; self.duration = duration
            self.elapsed = elapsed; self.playing = playing; self.rate = rate
            self.canNext = canNext; self.canPrevious = canPrevious
        }

        /// Whether Now Playing's info must be set again, `seconds` after it
        /// was set to `old`: anything but the elapsed time changed, or that
        /// moved more than 2 s from where the old rate had it.
        public func needsInfo(after old: Shown?, seconds: Double) -> Bool {
            guard let old else { return true }
            var a = self, b = old
            a.elapsed = nil; b.elapsed = nil
            if a != b { return true }
            switch (elapsed, old.elapsed) {
            case (nil, nil): return false
            case let (e?, o?): return abs(e - (o + old.rate * seconds)) > 2
            default: return true
            }
        }
    }

    /// Whether Now Playing's info must be set again. macOS moves the elapsed
    /// time on by itself from the info last set, so a new `Shown` is compared
    /// with that one and the time since it was set, not with the last shown.
    public struct InfoGate {
        private var set: Shown?
        private var at = 0.0

        public init() {}

        /// Whether `s` must be set at `now`; when it must, it counts as set.
        public mutating func needsSet(_ s: Shown, now: Double) -> Bool {
            guard s.needsInfo(after: set, seconds: now - at) else { return false }
            set = s
            at = now
            return true
        }

        /// The info was cleared (Now Playing given up).
        public mutating func cleared() { set = nil }
    }

    public static let settle = 1.5
    public static let stopRelease = 3.0
    public static let helloGrace = 3.0
    public static let retakeEvery = 10.0
    public static let lease = 45.0
    public static let pausedRelease = 1800.0
    /// After the Mac's play or pause, the agent's next states have this long to agree.
    public static let commandHold = 1.5

    public private(set) var on: Bool
    public private(set) var claimed = false
    public private(set) var shownPlaying = false
    /// The agent's last state, and the last one with a player (Now Playing's text).
    public private(set) var last: GuestState?
    private var info: GuestState?
    private var linked = false
    private var helloSeen = false
    private var invited = false
    private var guestID: String?
    private var lastLine: Double?
    private var notPlayingSince: Double?
    private var stoppedSince: Double?
    private var pausedSince: Double?
    private var lastTake = -Double.infinity
    private var graceUntil: Double?
    private var held: (playing: Bool, until: Double)?
    private var asleep = false

    public init(on: Bool) { self.on = on }

    public var shown: Shown? {
        guard claimed, let s = info ?? last else { return nil }
        return Shown(title: s.title.isEmpty ? s.player : s.title, artist: s.artist, album: s.album,
                     duration: s.length, elapsed: s.position, playing: shownPlaying,
                     rate: shownPlaying ? s.rate : 0, canNext: s.canNext, canPrevious: s.canPrevious)
    }

    /// When `tick` is due next (nil: nothing waits).
    public var deadline: Double? {
        guard claimed else { return nil }
        var d: [Double] = []
        if let h = held { d.append(h.until) }
        if last?.status == .playing, !shownPlaying { d.append(lastTake + Self.retakeEvery) }
        if shownPlaying, last?.status != .playing, let n = notPlayingSince { d.append(n + Self.settle) }
        if let s = stoppedSince { d.append(s + Self.stopRelease) }
        if let p = pausedSince { d.append(p + Self.pausedRelease) }
        if let g = graceUntil { d.append(g) }
        if !asleep, let l = lastLine { d.append(l + Self.lease) }
        return d.min()
    }

    /// A new connection to the port (QEMU's socket): the agent must say hello on it.
    public mutating func connected() {
        linked = true
        helloSeen = false
        invited = false
    }

    /// The connection ended. The claim stays: QEMU ending is `stop`, anything
    /// else reconnects within a second, and the lease covers an agent that
    /// never comes back.
    public mutating func disconnected() {
        linked = false
        helloSeen = false
    }

    public mutating func received(_ m: GuestMessage, now: Double) -> [Effect] {
        switch m {
        case .hello(let v, let id):
            var fx: [Effect] = [.send(MediaLine.hello(on: on, id: id))]
            if id != guestID {
                fx.append(.log("the VM's agent is there (v\(v))"))
                // An agent that started again (apply, a crash) while claimed.
                if claimed { graceUntil = now + Self.helloGrace }
            }
            helloSeen = true
            guestID = id
            lastLine = now
            return fx + settle(now)
        case .state(let s):
            guard helloSeen else {
                // A line before any hello on this connection: ask for one, once.
                guard linked, !invited else { return [] }
                invited = true
                return [.send(MediaLine.hello(on: on, id: nil))]
            }
            lastLine = now
            guard on else { return [] }
            return take(s, now: now)
        }
    }

    private mutating func take(_ s: GuestState, now: Double) -> [Effect] {
        let wasPlaying = last?.status == .playing
        last = s
        if s.status != .none { info = s }
        graceUntil = nil
        var fx: [Effect] = []
        switch s.status {
        case .playing:
            notPlayingSince = nil; stoppedSince = nil; pausedSince = nil
            if !claimed {
                claimed = true
                shownPlaying = true
                lastTake = now
                held = nil
                fx.append(.log("Now Playing is the VM (\(s.player.isEmpty ? "a player" : s.player) playing)"))
            }
        case .paused:
            if wasPlaying || notPlayingSince == nil { notPlayingSince = now }
            stoppedSince = nil
            if pausedSince == nil { pausedSince = now }
        case .stopped, .none:
            if wasPlaying || notPlayingSince == nil { notPlayingSince = now }
            pausedSince = nil
            if stoppedSince == nil { stoppedSince = now }
        }
        return fx + settle(now)
    }

    /// What is due at `now`: Now Playing's state after the waits, and giving up.
    public mutating func tick(now: Double) -> [Effect] { settle(now) }

    private mutating func settle(_ now: Double) -> [Effect] {
        guard claimed, let s = last else { return [] }
        if let h = held, now < h.until {
            shownPlaying = h.playing
        } else {
            held = nil
            if s.status == .playing {
                if !shownPlaying, now >= lastTake + Self.retakeEvery {
                    shownPlaying = true
                    lastTake = now
                }
            } else if shownPlaying, let n = notPlayingSince, now >= n + Self.settle {
                shownPlaying = false
            }
        }
        if let t = stoppedSince, now >= t + Self.stopRelease { return release("nothing plays in the VM") }
        if let p = pausedSince, now >= p + Self.pausedRelease { return release("paused for 30 minutes") }
        if let g = graceUntil, now >= g { return release("the VM's agent started again and named no player") }
        if !asleep, let l = lastLine, now >= l + Self.lease { return release("no word from the VM's agent for 45 s") }
        return []
    }

    private mutating func release(_ why: String) -> [Effect] {
        guard claimed else { return [] }
        claimed = false
        shownPlaying = false
        held = nil
        graceUntil = nil
        return [.log("Now Playing given up (\(why))")]
    }

    /// The app's switch changed while the VM runs.
    public mutating func switched(_ on: Bool, now: Double) -> [Effect] {
        guard on != self.on else { return [] }
        self.on = on
        var fx: [Effect] = [.log("\(on ? "on" : "off") (switched while the VM runs)")]
        // The agent's next state after the hello is fresh; nothing from before counts.
        last = nil; info = nil
        notPlayingSince = nil; stoppedSince = nil; pausedSince = nil
        if linked, helloSeen { fx.append(.send(MediaLine.hello(on: on, id: guestID))) }
        if !on { fx += release("the app's switch is off") }
        return fx
    }

    /// A command from macOS (AirPods, Control Center, a play key): what to
    /// send the VM, from the agent's own last state (not what Now Playing shows).
    public func command(_ c: RemoteCommand) -> Answer {
        guard claimed, on, let s = last else { return .notClaimed }
        guard linked, helloSeen else { return .noLink }
        switch c {
        case .play: return .send(.play)
        case .pause, .stop: return .send(.pause)
        case .togglePlayPause: return .send(s.status == .playing ? .pause : .play)
        case .nextTrack: return .send(.next)
        case .previousTrack: return .send(.previous)
        }
    }

    /// The command went into the port: Now Playing follows at once (the
    /// agent's next state confirms or corrects it).
    public mutating func commandSent(_ c: RemoteCommand, _ m: MacCommand, now: Double) -> [Effect] {
        switch m {
        case .play:
            held = (true, now + Self.commandHold)
            shownPlaying = true
            if last?.status != .playing { notPlayingSince = now }
        case .pause:
            held = (false, now + Self.commandHold)
            shownPlaying = false
        case .next, .previous:
            break
        }
        return [.log("\(c.rawValue) from macOS: \(m.rawValue) to the VM's player")]
    }

    /// The Mac goes to sleep: the claim stays, the lease waits.
    public mutating func sleep() { asleep = true }

    /// The Mac woke: the lease starts again, and the agent is asked for a fresh state.
    public mutating func wake(now: Double) -> [Effect] {
        asleep = false
        if lastLine != nil { lastLine = now }
        guard linked, helloSeen else { return [] }
        return [.send(MediaLine.hello(on: on, id: guestID))]
    }

    /// QEMU ended (or the launcher stops the VM): give Now Playing up now.
    public mutating func stop(_ why: String) -> [Effect] {
        linked = false
        helloSeen = false
        return release(why)
    }
}
