import Foundation

/// The playback buffers QEMU asks the Mac's output for (#548).
///
/// SDL3 opens CoreAudio's AudioQueue at QEMU's rate (at least 44.1 kHz)
/// with the frames per callback QEMU asks for: 48 kHz and 256 frames (6
/// queue buffers) on the sound's own thread, 44.1 kHz and 512 (4 queue
/// buffers) on QEMU's main loop. AirPods over A2DP refused to start the own
/// thread's queue (AudioQueueStart -66681) and played the main loop's.
/// A start with a wireless output gives the own thread the main loop's
/// queue (AudioPath.threadWirelessOptions); while the VM runs, the app
/// writes the size the Mac's output needs into a file QEMU reads before
/// each open and while it plays (qemu-sdl-audio-out-size.patch,
/// OMACVM_AUDIO_OUT_FRAMES_FILE), and QEMU tries the next size itself when
/// a start is refused.
public enum AudioOutputSize {
    /// At least this for wireless outputs: the main loop path's size, the
    /// one the reporter's AirPods played.
    public static let wirelessFrames = 512

    /// A CoreAudio four-character code (kAudioDeviceTransportType...).
    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// Bluetooth, Bluetooth LE, AirPlay: outputs with a long delay of
    /// their own (AirPods: 170 ms), where the extra 11 ms do not count.
    static let wireless: Set<UInt32> = [fourCC("blue"), fourCC("blea"), fourCC("airp")]

    /// The frames the output with this transport type needs at least;
    /// 0: the sound path's own size.
    public static func minimumFrames(transport: UInt32?) -> Int {
        guard let t = transport else { return 0 }
        return wireless.contains(t) ? wirelessFrames : 0
    }

    /// The frames per callback of a start's options (AudioPath): 256 on the
    /// own thread, 512 on the main loop and on the own thread started with a
    /// wireless output.
    public static func ownFrames(thread: Bool, wireless: Bool = false) -> Int { thread && !wireless ? 256 : 512 }

    /// The rate QEMU gives SDL with a start's options: 48 kHz on the own
    /// thread, 44.1 kHz on the main loop and the own thread's wireless start.
    public static func rate(thread: Bool, wireless: Bool = false) -> Double { thread && !wireless ? 48000 : 44100 }

    /// What QEMU opens with for an output that needs MINIMUM.
    public static func frames(thread: Bool, wireless: Bool = false, minimum: Int) -> Int {
        max(ownFrames(thread: thread, wireless: wireless), minimum)
    }

    /// SDL3's AudioQueue length in ms: 3 buffers, or as many (an even
    /// count) as cover 15 ms twice when one is shorter than 15 ms.
    public static func queueMs(frames: Int, rate: Double = 48000) -> Double {
        let ms = Double(frames) / rate * 1000
        guard ms > 0 else { return 0 }
        let buffers = ms < 15 ? Int((15 / ms).rounded(.up)) * 2 : 3
        return Double(buffers) * ms
    }

    /// The file's text: the frames and a newline (0: no wish).
    public static func fileText(frames: Int) -> String { "\(frames)\n" }
}

/// When the app writes QEMU's size file anew (#548). A new file (a new
/// inode) also tells QEMU to forget what the last output refused: after
/// every size was refused, QEMU makes no new start until the file changes.
/// So the file is written for every other output, also with the same size,
/// and once more after coreaudiod restarted (`sudo killall coreaudiod`, the
/// known way out of a silent output), even when the same output comes back
/// with the same ID.
public struct AudioSizeFile: Equatable {
    /// The size in the file now.
    public private(set) var frames: Int
    /// The output it was written for; nil: none known (forgotten).
    public private(set) var device: UInt32?

    public init(frames: Int, device: UInt32) {
        self.frames = frames
        self.device = device
    }

    /// Whether the file needs writing for output DEVICE, which needs MINIMUM.
    public func needsWrite(minimum: Int, device: UInt32) -> Bool {
        minimum != frames || device != self.device
    }

    /// The file now holds MINIMUM for DEVICE.
    public mutating func written(minimum: Int, device: UInt32) {
        frames = minimum
        self.device = device
    }

    /// coreaudiod restarted: the next look writes the file whatever output
    /// it finds.
    public mutating func serviceRestarted() {
        device = nil
    }
}
