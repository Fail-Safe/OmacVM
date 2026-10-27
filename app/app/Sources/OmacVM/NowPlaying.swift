import Foundation
import MediaPlayer
import OmacVMMedia

/// AirPods and media controls (docs/adr/0058-now-playing.md): while the VM
/// plays, this process (the launcher, which macOS names with the app's name)
/// is the Mac's Now Playing app, so AirPods, other Bluetooth headphones,
/// Control Center and the play keys reach the VM's player.
///
/// Threads: everything here runs on the main thread. MediaSession owns the
/// rules (MediaClaim, with the uptime as its clock: the Mac's sleep does not
/// count) and the port's connection; NowPlaying is the one MPRemoteCommandCenter
/// and MPNowPlayingInfoCenter of the process. The Runner gives Now Playing up
/// in its QEMU-exit handler, before anything else happens to the launcher
/// (it stays alive after a crash, a Vulkan fallback or a lost drive).
@MainActor
final class MediaSession {
    private var claim: MediaClaim
    private var bridge: NativeMediaBridge?
    private let log: (String) -> Void
    private var timer: Timer?
    private var retry: Timer?
    /// The Mac's last hello the port did not take (it was full): tried again.
    private var unsent: Data?
    private var watch: NSKeyValueObservation?
    private var lastDropLog = -Double.infinity
    private var stopped = false

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(log: @escaping (String) -> Void) {
        self.log = log
        claim = MediaClaim(on: Settings.mediaControls)
        // The switch counts at once (the window's row, defaults write).
        watch = UserDefaults.standard.observe(\.mediaControls) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.switched() } }
        }
    }

    /// A new connection to QEMU's socket (the reconnect thread, on main).
    /// False after QEMU ended: the descriptor is closed, nothing reads it.
    func attach(_ b: NativeMediaBridge) -> Bool {
        guard !stopped else { b.close(); return false }
        bridge = b
        unsent = nil
        claim.connected()
        return true
    }

    /// Its read ended.
    func detach(_ b: NativeMediaBridge) {
        b.close()
        guard bridge === b else { return }
        bridge = nil
        unsent = nil
        claim.disconnected()
        apply()
    }

    func received(_ m: GuestMessage) {
        guard !stopped else { return }
        run(claim.received(m, now: Self.now))
    }

    /// Lines the VM sent too long or too fast: said at most once a minute.
    func dropped(_ why: String) {
        let now = Self.now
        guard now - lastDropLog >= 60 else { return }
        lastDropLog = now
        log("OmacVM: media controls: lines from the VM dropped (\(why))")
    }

    func sleep() { claim.sleep(); schedule() }
    func wake() { run(claim.wake(now: Self.now)) }

    /// QEMU ended: Now Playing is given up now, the switch no longer watched.
    func stop(_ why: String) {
        guard !stopped else { return }
        run(claim.stop(why))
        stopped = true
        watch?.invalidate()
        watch = nil
        timer?.invalidate()
        timer = nil
        retry?.invalidate()
        retry = nil
        NowPlaying.shared.release(for: self)
    }

    private func switched() {
        guard !stopped else { return }
        run(claim.switched(Settings.mediaControls, now: Self.now))
    }

    private func run(_ fx: [MediaClaim.Effect]) {
        for e in fx {
            switch e {
            // Every line from the rules is the Mac's hello (an answer, the
            // switch, a wake): one the port did not take is tried again, as the
            // agent would keep the old switch until its next start.
            case .send(let line): if let b = bridge { unsent = b.write(line) ? nil : line }
            case .log(let line): log("OmacVM: media controls: \(line)")
            }
        }
        retryLater()
        apply()
    }

    /// The port was full: the rest of a part-sent line and an unsent hello
    /// are tried again every second (nothing else would send them soon).
    private func retryLater() {
        guard retry == nil, let b = bridge, b.hasPending || unsent != nil else { return }
        let t = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retry = nil
                guard !self.stopped, let b = self.bridge else { return }
                if let line = self.unsent {
                    if b.write(line) { self.unsent = nil }
                } else {
                    _ = b.flush()
                }
                self.retryLater()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retry = t
    }

    private func apply() {
        guard !stopped else { return }
        NowPlaying.shared.show(claim.shown, for: self)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let at = claim.deadline else { return }
        let t = Timer(timeInterval: max(0.05, at - Self.now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.run(self.claim.tick(now: Self.now))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A command from macOS while this session holds Now Playing.
    func command(_ c: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        switch claim.command(c, now: Self.now) {
        case .notClaimed:
            return .noActionableNowPlayingItem
        case .noLink:
            log("OmacVM: media controls: \(c.rawValue) from macOS: not sent (the VM's agent is not connected)")
            return .commandFailed
        case .send(let m):
            guard let b = bridge, b.write(MediaLine.command(m)) else {
                log("OmacVM: media controls: \(c.rawValue) from macOS: not sent (the VM's port is full)")
                return .commandFailed
            }
            run(claim.commandSent(c, m, now: Self.now))   // also tries a part-sent rest again
            return .success
        }
    }
}

/// The process's Now Playing registration: command targets and the info
/// macOS shows (Control Center). Targets present and `.playing` once make
/// this process Now Playing; paused it stays; removing the targets gives it
/// up (tracks/airpods-media.md, the spike). Skip, seek and the rest stay off,
/// so a double or triple press stays next and previous. Main thread only.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private weak var owner: MediaSession?
    private var registered = false
    private var infoGate = MediaClaim.InfoGate()

    private var commands: [(MPRemoteCommand, RemoteCommand)] {
        let c = MPRemoteCommandCenter.shared()
        return [(c.playCommand, .play), (c.pauseCommand, .pause), (c.togglePlayPauseCommand, .togglePlayPause),
                (c.stopCommand, .stop), (c.nextTrackCommand, .nextTrack), (c.previousTrackCommand, .previousTrack)]
    }

    private var unused: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand,
                c.changePlaybackPositionCommand, c.changePlaybackRateCommand, c.changeRepeatModeCommand,
                c.changeShuffleModeCommand, c.ratingCommand, c.likeCommand, c.dislikeCommand, c.bookmarkCommand,
                c.enableLanguageOptionCommand, c.disableLanguageOptionCommand]
    }

    func show(_ s: MediaClaim.Shown?, for session: MediaSession) {
        guard let s else {
            release(for: session)
            return
        }
        owner = session
        if !registered {
            for (cmd, rc) in commands {
                cmd.isEnabled = true
                cmd.addTarget { _ in
                    if Thread.isMainThread { return MainActor.assumeIsolated { NowPlaying.shared.handle(rc) } }
                    return DispatchQueue.main.sync { MainActor.assumeIsolated { NowPlaying.shared.handle(rc) } }
                }
            }
            for cmd in unused { cmd.isEnabled = false }
            registered = true
        }
        let c = MPRemoteCommandCenter.shared()
        if c.nextTrackCommand.isEnabled != s.canNext { c.nextTrackCommand.isEnabled = s.canNext }
        if c.previousTrackCommand.isEnabled != s.canPrevious { c.previousTrackCommand.isEnabled = s.canPrevious }
        let center = MPNowPlayingInfoCenter.default()
        if infoGate.needsSet(s, now: MediaSession.now) {
            var info: [String: Any] = [MPMediaItemPropertyTitle: s.title,
                                       MPNowPlayingInfoPropertyPlaybackRate: s.rate,
                                       MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
            if !s.artist.isEmpty { info[MPMediaItemPropertyArtist] = s.artist }
            if !s.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = s.album }
            if let d = s.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
            if let e = s.elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = e }
            center.nowPlayingInfo = info
        }
        let state: MPNowPlayingPlaybackState = s.playing ? .playing : .paused
        if center.playbackState != state { center.playbackState = state }
    }

    /// Gives Now Playing up: no targets, no info, stopped.
    func release(for session: MediaSession) {
        guard registered, owner == nil || owner === session else { return }
        for (cmd, _) in commands {
            cmd.removeTarget(nil)
            cmd.isEnabled = false
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        registered = false
        infoGate.cleared()
        owner = nil
    }

    private func handle(_ c: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        owner?.command(c) ?? .noActionableNowPlayingItem
    }
}

extension UserDefaults {
    /// For KVO on the switch (MediaSession); the value is Settings.mediaControls.
    @objc dynamic var mediaControls: Bool { bool(forKey: MediaControls.key) }
}
