import Darwin
import Foundation
import OmacVMMedia

/// The launcher's end of the org.omacvm.media port (AirPods and media
/// controls, MediaPort): one connection to QEMU's socket.
///
/// Threads: `read` runs on the Runner's reconnect thread until QEMU closes
/// the socket. It cuts lines (MediaLines: 4 KB, 20 a second), parses them
/// and hands each message to the main thread. The main thread owns the rest:
/// it writes with MSG_DONTWAIT (never blocks; a full port drops the line,
/// and a line the port took only part of goes out first next time), and it
/// closes the descriptor, only after `read` has ended.
final class NativeMediaBridge: @unchecked Sendable {
    let fd: Int32
    private var closed = false       // main thread
    private var pending = Data()     // main thread

    init(fd: Int32) { self.fd = fd }

    /// Reads until the socket ends. `message` and `dropped` run on the main thread.
    func read(message: @escaping @MainActor (GuestMessage) -> Void, dropped: @escaping @MainActor (String) -> Void) {
        var lines = MediaLines()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var long = 0, fast = 0
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for line in lines.feed(chunk[0..<n], now: now) {
                guard let m = MediaLine.parse(line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { message(m) } }
            }
            if lines.droppedLong != long || lines.droppedFast != fast {
                let why = lines.droppedLong != long ? "over 4 KB" : "over 20 a second"
                long = lines.droppedLong; fast = lines.droppedFast
                DispatchQueue.main.async { MainActor.assumeIsolated { dropped(why) } }
            }
        }
    }

    /// One line to the VM, without waiting: false when the port did not take it.
    @MainActor func write(_ line: Data) -> Bool {
        guard !closed else { return false }
        if !pending.isEmpty {
            let n = send(pending)
            pending.removeFirst(max(0, n))
            guard pending.isEmpty else { return false }
        }
        let n = send(line)
        if n <= 0 { return false }
        if n < line.count { pending = line.subdata(in: n..<line.count) }
        return true
    }

    @MainActor private func send(_ d: Data) -> Int {
        d.withUnsafeBytes { b in
            while true {
                let n = Darwin.send(fd, b.baseAddress, b.count, MSG_DONTWAIT)
                if n < 0, errno == EINTR { continue }
                return n
            }
        }
    }

    /// After `read` returned.
    @MainActor func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
