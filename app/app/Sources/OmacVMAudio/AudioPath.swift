import Foundation

/// Where QEMU moves the VM's sound (audio lane, 3.1.16): in its main loop
/// with the VM's GPU (up to 3.1.14), or on a real-time thread of its own
/// (qemu-audio-own-thread.patch, OMACVM_AUDIO_THREAD=1).
public enum AudioPath {
    /// The sound's own thread unless the person switched back.
    public static let threadByDefault = false
    /// QEMU's ring on the sound's own thread: it covers the guest's stalls
    /// only, not the main loop's.
    public static let threadRing = "out.buffer-count=8"
}
