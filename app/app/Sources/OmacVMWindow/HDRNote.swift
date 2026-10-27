import Foundation

/// What the HDR row says about the VM that runs now (HDRRow in the app).
/// HDR and 10-bit colour is read when the VM starts (Settings.hdrStart): the
/// VM loads its 10-bit graphics driver at boot and QEMU shows HDR from then
/// on. A restart inside the VM keeps QEMU and that start's answer, so a
/// change of the switch counts only once the VM is shut down and started
/// again, which is easy to miss. The app writes the start's answer near the
/// top of qemu.log, "OmacVM: HDR: on (...)" or "OmacVM: HDR: off (why)", and
/// only when the switch was on at that start: no line means the VM started
/// with the switch off. Apps since HDR came (ADR 0049) write the same line,
/// so a VM started by an older app reads the same.
public enum HDRNote {
    /// This start's answer from the head of qemu.log: on, off with why (the
    /// switch was on, HDR was not), or nil (no line: the switch was off).
    public static func startAnswer(_ log: String) -> (on: Bool, why: String)? {
        let tag = "OmacVM: HDR: "
        guard let line = log.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(tag) }) else { return nil }
        let rest = line.dropFirst(tag.count)
        var why = ""
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            why = String(rest[rest.index(after: open)..<close])
        }
        if rest.hasPrefix("on") { return (true, why) }
        if rest.hasPrefix("off") { return why == "switch off" ? nil : (false, why) }
        return nil
    }

    /// The row's subtitle without a note.
    public static let usual = "Deeper colour, and HDR from Linux apps that send it. Counts when the VM starts, not at a restart inside it."

    /// The row's subtitle, and whether it is a note about the running VM
    /// (the row shows it in orange). The note wins over GPU safe mode's
    /// line: safe mode also counts only from the next start, so a VM that
    /// started with HDR keeps it until then.
    /// - switchOn: the switch now (Settings.hdr); safeMode: Settings.gpuSafeMode.
    public static func subtitle(switchOn: Bool, safeMode: Bool, running: Bool, log: String?) -> (text: String, isNote: Bool) {
        if let n = note(switchOn: switchOn && !safeMode, running: running, log: log) { return (n, true) }
        return (safeMode ? "Off while GPU safe mode is on." : usual, false)
    }

    /// The row's note; nil: the usual subtitle.
    /// - switchOn: what the next start takes (the switch, and no GPU safe mode).
    /// - running: this VM runs now.
    /// - log: the head of its logs/qemu.log (nil: none).
    public static func note(switchOn: Bool, running: Bool, log: String?) -> String? {
        guard running, let log else { return nil }
        let start = startAnswer(log)
        switch (switchOn, start) {
        case (false, .some(let s)) where s.on:
            return "This VM still runs with HDR. It goes off when you shut the VM down and start it again; a restart inside the VM keeps it."
        case (true, .none):
            return "This VM runs without HDR. It comes on when you shut the VM down and start it again; a restart inside the VM keeps it off."
        case (true, .some(let s)) where !s.on:
            return s.why.isEmpty ? "This start of the VM has no HDR." : "This start of the VM has no HDR: \(s.why)."
        default:
            return nil
        }
    }
}
