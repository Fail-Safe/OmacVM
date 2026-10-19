import Foundation
import OmacVMWindow

/// The VM folder's SSH key into the VM through the guest agent, without SSH
/// (SSHRepair has the rules): at each window start (Runner) and in Update VM
/// when SSH turns the key down (Creator).
enum VMKey {
    /// The folder's public key line (app_ssh_key does the same). A missing
    /// ssh-key.pub comes from ssh-key (ssh-keygen -y): the VM may know that
    /// key, so it is never replaced while it is there. Only without ssh-key
    /// is a new one made (ssh-keygen writes it 600 itself). nil: no usable key.
    static func keyLine(folder: URL) -> String? {
        let key = folder.appendingPathComponent("ssh-key"), pub = folder.appendingPathComponent("ssh-key.pub")
        let fm = FileManager.default
        if fm.fileExists(atPath: key.path), !fm.fileExists(atPath: pub.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)   // ssh-keygen refuses an open key
            if let out = keygen(["-y", "-f", key.path]), SSHRepair.keyLine(pub: out) != nil {
                try? out.write(to: pub, options: .atomic)
            }
        }
        if !fm.fileExists(atPath: key.path) || !fm.fileExists(atPath: pub.path) {
            try? fm.removeItem(at: key)
            try? fm.removeItem(at: pub)
            guard keygen(["-t", "ed25519", "-N", "", "-C", "omacvm-vm", "-f", key.path, "-q"]) != nil else { return nil }
        }
        return (try? Data(contentsOf: pub)).flatMap(SSHRepair.keyLine)
    }

    /// ssh-keygen ARGS: its output, nil when it failed.
    private static func keygen(_ args: [String]) -> Data? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// The by-hand command with the folder's key (Copy Command). Reads the
    /// key only; nil when the folder has none.
    static func manualCommand(folder: URL) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent("ssh-key.pub")))
            .flatMap(SSHRepair.keyLine).flatMap(SSHRepair.manualCommand)
    }

    /// Adds the folder's key in the VM when it is missing. Waits up to
    /// `pingWait` seconds for the guest agent, while `running`. Off the main
    /// thread: it blocks for as long as that.
    static func ensure(folder: URL, agentPath: String, pingWait: Double, running: () -> Bool) -> SSHRepair.Result {
        guard let key = keyLine(folder: folder) else { return .failed("no usable key in the VM folder") }
        let deadline = Date().addingTimeInterval(pingWait)
        var up = false
        while running(), Date() < deadline {
            if GuestAgent.execute(socketPath: agentPath, "{\"execute\":\"guest-ping\"}")?.contains("\"return\"") == true { up = true; break }
            Thread.sleep(forTimeInterval: 2)
        }
        guard up, running() else { return .noAgent }
        let c = SSHRepair.command(key: key)
        switch GuestAgent.runAndWait(socketPath: agentPath, c.path, c.args, seconds: 30) {
        case .exited(0, let out):
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "added": return .added
            case "present": return .present
            default: return .failed("an unexpected answer")
            }
        case .exited(let code, _): return .failed("exit \(code)")
        case .noAgent: return .noAgent
        case .refused(let why): return .failed("the guest agent refused: \(why)")
        case .running: return .failed("no result within 30 s")
        case .badReply: return .failed("an unreadable reply")
        }
    }
}
