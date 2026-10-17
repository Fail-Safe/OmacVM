import Foundation

/// A VM feature switched in the app's window while the VM is stopped (#316):
/// the VM's record (its features file) says the choice at once, a pending file
/// in the VM's folder remembers it, and at the next start, once the VM
/// answers, the app's omacvm sets up the VM's part (apply's switch of that
/// feature alone) and removes the file. Used by Mac input (mac-ime, off by
/// default) and WebGPU and GPU compute (gpu-compute, on by default).
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public struct PendingSwitch {
    public let feature: String
    /// What a record without the feature's word means.
    public let defaultOn: Bool
    public var pendingFile: String { "\(feature)-pending" }

    public init(feature: String, defaultOn: Bool) { self.feature = feature; self.defaultOn = defaultOn }

    /// The record's word for it; the last one counts.
    public func isOn(features text: String?) -> Bool {
        var on = defaultOn
        for word in (text ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Substring(feature) { on = kv[1] == "on" }
        }
        return on
    }

    /// The pending choice from that file's text; nil when there is none.
    public func pending(_ text: String?) -> Bool? {
        switch text?.split(whereSeparator: { $0 == " " || $0 == "\n" }).first {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// A switch while the VM is stopped: the new record (the feature set, the
    /// other words as they were) and the pending file's text, nil to remove
    /// it (switched back before a start: the VM still has what it had).
    public func switchStopped(record: String?, pending current: String?, on: Bool) -> (record: String, pending: String?) {
        var words = (record ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let word = "\(feature)=\(on ? "on" : "off")"
        if let i = words.firstIndex(where: { $0.hasPrefix("\(feature)=") }) { words[i] = word } else { words.append(word) }
        let p = pending(current)
        let next: String? = p == nil ? (on ? "on" : "off") : (p == on ? (on ? "on" : "off") : nil)
        return (words.joined(separator: " ") + "\n", next.map { $0 + "\n" })
    }

    /// At the VM's start: the pending choice, or nil; the record (FOLDER/features)
    /// follows it (an apply that failed and rolled back may have reset it).
    public func prepareStart(folder f: URL) -> Bool? {
        guard let on = pending(try? String(contentsOf: f.appendingPathComponent(pendingFile), encoding: .utf8)) else { return nil }
        let url = f.appendingPathComponent("features")
        let text = try? String(contentsOf: url, encoding: .utf8)
        if isOn(features: text) != on {
            try? switchStopped(record: text, pending: nil, on: on).record.write(to: url, atomically: true, encoding: .utf8)
        }
        return on
    }

    /// The app's omacvm at the start: the VM's part for the pending choice
    /// (only that part: apply's feature switch).
    public func applyArguments(vm: String, on: Bool) -> [String] {
        ["apply", "--vm", vm, "--vm-type", "app", "--feature", "\(feature)=\(on ? "on" : "off")", "--yes", "--transaction"]
    }
}
