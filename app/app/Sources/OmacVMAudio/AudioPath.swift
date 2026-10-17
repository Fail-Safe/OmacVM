import Foundation

/// Where QEMU moves the VM's sound (audio lane, 3.1.16): in its main loop
/// with the VM's GPU (up to 3.1.14), or on a real-time thread of its own
/// (qemu-audio-own-thread.patch, OMACVM_AUDIO_THREAD=1).
public enum AudioPath {
    /// On from 3.1.17 (3.1.16 shipped it off: lower latency and no breaks
    /// from the main loop, a draw with a busy GPU; the user's listening test
    /// on a MacBook Air was much better). Off: the VM window's Output switch,
    /// or defaults write org.omacvm.app audioThread -bool false.
    public static let threadByDefault = true
    /// The sound backend's options on the sound's own thread. The ring no
    /// longer covers the main loop's stalls, only the thread's own jitter:
    /// 6 blocks of 256 frames at 48 kHz (32 ms, the Mac's and the guest's
    /// rate, so nothing is resampled), instead of 8 x 512 at 44.1 kHz (93 ms).
    public static let threadOptions = "out.frequency=48000,in.frequency=48000,out.buffer-length=5334,out.buffer-count=6,in.buffer-length=10667"
    /// The main loop's (up to 3.1.14, and audioMainLoop).
    public static let mainLoopOptions = "out.buffer-count=8"
}
