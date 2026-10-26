import CoreAudio
import Foundation
import OmacVMAudio

/// Tells the VM how late the Mac plays its sound (AudioDelay: QEMU's buffers
/// plus the Mac's output device), so Chromium, Firefox and mpv in the VM hold
/// the picture back by as much (av-sync, 3.0.2). At the start, and whenever
/// the Mac's default output or its delay changes (AirPods: about 170 ms more).
///
/// Over the guest agent, as root: /usr/local/bin/omacvm-audio-latency MS. It
/// keeps the value and sets PipeWire's latency offset on the sound card's
/// output port. Until the VM's agent answers (the VM is still starting) it
/// tries again every 5 s for 5 minutes; a VM without the program (guest files
/// before 3.0.2) says no the same way and is left alone until the next change.
///
/// It also keeps QEMU's playback buffers right for the Mac's output (#548):
/// the frames that output needs (AudioOutputSize: 512 for AirPods) go into
/// the file QEMU reads (OMACVM_AUDIO_OUT_FRAMES_FILE), and into the delay.
final class AudioLatencyWatch: @unchecked Sendable {
    static let program = "/usr/local/bin/omacvm-audio-latency"
    static let firstSendSeconds = 8
    static let retrySeconds = 5
    static let maximumTries = 60
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private let agentSocket: String
    private let thread: Bool
    private let wireless: Bool
    private let framesFile: String?
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "org.omacvm.audio-latency")
    // On queue:
    private var sent: Int?
    private var wanted: Int?
    private var tries = 0
    private var retry: DispatchSourceTimer?
    private var device = AudioLatencyWatch.unknown
    private var stopped = false
    private var framesWritten: Int
    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }

    /// FRAMESFILE: QEMU's size file, holding INITIALFRAMES (written before
    /// QEMU started: Self.writeFrames).
    /// WIRELESS: the start's options were made for a wireless output.
    init(agentSocket: String, thread: Bool, wireless: Bool = false, framesFile: String? = nil, initialFrames: Int = 0,
         log: @escaping (String) -> Void) {
        self.agentSocket = agentSocket
        self.thread = thread
        self.wireless = wireless
        self.framesFile = framesFile
        self.framesWritten = initialFrames
        self.log = log
    }

    func start() {
        queue.async {
            var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.queue, self.changed)
        }
        // The first send once the VM had time to start its agent (and before
        // that, GuestAgent.hold gets the agent's one connection).
        queue.asyncAfter(deadline: .now() + .seconds(Self.firstSendSeconds)) { self.update() }
    }

    /// Not waiting: a send in progress can take the agent's 2 s.
    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.retry?.cancel()
            self.retry = nil
            var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.queue, self.changed)
            self.watchDevice(Self.unknown)
        }
    }

    // MARK: on queue

    private func update() {
        guard !stopped else { return }
        let id = Self.defaultOutput()
        watchDevice(id)
        let info = id == Self.unknown ? nil : Self.device(id)
        let minimum = id == Self.unknown ? 0 : AudioOutputSize.minimumFrames(transport: Self.transport(id))
        followSize(minimum, id)
        let outFrames = AudioOutputSize.frames(thread: thread, wireless: wireless, minimum: minimum)
        let ms = AudioDelay.total(deviceMs: info?.ms, extraMs: Settings.audioDelayExtraMs, thread: thread, wireless: wireless,
                                  outFrames: outFrames)
        if ms == sent {   // back to what the VM has: nothing to send
            wanted = nil
            retry?.cancel()
            retry = nil
            return
        }
        guard ms != wanted else { return }
        wanted = ms
        tries = 0
        let name = id == Self.unknown ? "none" : Self.name(id)
        let deviceText = info?.ms.map { String(format: "%.1f ms", $0) } ?? "unknown"
        log("OmacVM: sound delay for the VM: \(ms) ms (QEMU \(AudioDelay.qemuPart(thread: thread, wireless: wireless, outFrames: outFrames)) ms, Mac output '\(name)' \(deviceText)"
            + (Settings.audioDelayExtraMs != 0 ? ", audioDelayExtraMs \(Settings.audioDelayExtraMs)" : "") + ")")
        send()
    }

    private func send() {
        guard !stopped, let ms = wanted else { return }
        retry?.cancel()
        retry = nil
        if GuestAgent.run(socketPath: agentSocket, Self.program, [String(ms)]) {
            sent = ms
            wanted = nil
            return
        }
        tries += 1
        guard tries < Self.maximumTries else {
            log("OmacVM: the VM did not take the sound delay (no omacvm-audio-latency: guest files before 3.0.2?)")
            wanted = nil
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(Self.retrySeconds))
        t.setEventHandler { [weak self] in self?.send() }
        t.resume()
        retry = t
    }

    /// QEMU's size file for the Mac's output now (#548): AirPods and other
    /// wireless outputs refuse the own thread's 256-frame queue.
    private func followSize(_ minimum: Int, _ id: AudioObjectID) {
        guard let path = framesFile, minimum != framesWritten else { return }
        guard Self.writeFrames(path, minimum) else {
            log("OmacVM: sound: could not write the playback size for QEMU (\(path))")
            return
        }
        framesWritten = minimum
        let name = id == Self.unknown ? "none" : Self.name(id)
        log(minimum > 0
            ? "OmacVM: sound: Mac output '\(name)' is wireless: playback buffers of at least \(minimum) frames"
            : "OmacVM: sound: Mac output '\(name)': the sound path's own playback buffers")
    }

    /// Writes QEMU's size file in one step (a new file each time, which
    /// QEMU notices by its inode).
    @discardableResult
    static func writeFrames(_ path: String, _ frames: Int) -> Bool {
        (try? AudioOutputSize.fileText(frames: frames).write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// The frames the Mac's default output needs now (0: the path's own).
    static func minimumFramesNow() -> Int {
        let id = defaultOutput()
        return id == unknown ? 0 : AudioOutputSize.minimumFrames(transport: transport(id))
    }

    static func transport(_ id: AudioObjectID) -> UInt32? {
        get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))
    }

    /// Follows the delay of the device in use (Bluetooth changes it while it runs).
    private func watchDevice(_ id: AudioObjectID) {
        guard id != device else { return }
        let selectors = [kAudioDevicePropertyLatency, kAudioDevicePropertyBufferFrameSize,
                         kAudioDevicePropertySafetyOffset, kAudioDevicePropertyNominalSampleRate]
        if device != Self.unknown {
            for s in selectors {
                var a = Self.address(s, scope(s))
                AudioObjectRemovePropertyListenerBlock(device, &a, queue, changed)
            }
        }
        device = id
        if id != Self.unknown {
            for s in selectors {
                var a = Self.address(s, scope(s))
                AudioObjectAddPropertyListenerBlock(id, &a, queue, changed)
            }
        }
    }

    private func scope(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyScope {
        s == kAudioDevicePropertyNominalSampleRate ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeOutput
    }

    // MARK: CoreAudio

    private static func address(_ s: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ id: AudioObjectID, _ s: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
        var a = address(s, scope)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func defaultOutput() -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal, Self.unknown) ?? Self.unknown
    }

    /// What a Mac app adds to its own A/V sync: the device's latency, safety
    /// offset and buffer, and its first output stream's latency.
    static func device(_ id: AudioObjectID) -> AudioDelay.Device? {
        let out = kAudioDevicePropertyScopeOutput
        guard let rate = get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) else { return nil }
        var streamLatency: UInt32 = 0
        var a = address(kAudioDevicePropertyStreams, out)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &streams) == noErr, let s = streams.first {
                streamLatency = get(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
            }
        }
        return AudioDelay.Device(latency: get(id, kAudioDevicePropertyLatency, out, UInt32(0)) ?? 0,
                                 safetyOffset: get(id, kAudioDevicePropertySafetyOffset, out, UInt32(0)) ?? 0,
                                 streamLatency: streamLatency,
                                 bufferFrames: get(id, kAudioDevicePropertyBufferFrameSize, out, UInt32(0)) ?? 0,
                                 sampleRate: rate)
    }

    static func name(_ id: AudioObjectID) -> String {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return "device \(id)" }
        return n.takeRetainedValue() as String
    }
}
