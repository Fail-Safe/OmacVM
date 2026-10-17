import Foundation

/// WebGPU and GPU compute on the VM's Vulkan (feature gpu-compute, on by
/// default; src/app/guest/venus/compute.sh): OpenCL, the "Chromium (WebGPU)"
/// entry and Firefox's WebGPU while the VM's Graphics gives it Vulkan. The
/// VM window's row switches it with `omacvm enable|disable gpu-compute`
/// while the VM runs (its part is in the VM). Apart from the UI so it is
/// tested without a VM: `swift run features-tests`.
public enum GPUCompute {
    public static let feature = "gpu-compute"

    /// The record's word for it. On by default: a record without the word
    /// (a VM from before 3.1.20, or none yet) is on, as apply will make it.
    public static func isOn(features text: String?) -> Bool {
        var on = true
        for word in (text ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Substring(feature) { on = kv[1] != "off" }
        }
        return on
    }

    /// The row: on or off, whether it can be switched now, and its note.
    public struct Row: Equatable {
        public var on: Bool
        public var enabled: Bool
        public var note: String?
        public init(on: Bool, enabled: Bool, note: String?) { self.on = on; self.enabled = enabled; self.note = note }
    }

    /// `vulkan`: the VM's next start has Vulkan (Graphics). Stopped: nothing
    /// to switch (the part is in the VM; `omacvm enable` would start it).
    public static func row(record: String?, running: Bool, vulkan: Bool, busy: Bool, cli: Bool) -> Row {
        let on = isOn(features: record)
        if busy { return Row(on: on, enabled: false, note: nil) }
        if !running { return Row(on: on, enabled: false, note: "Switch it while the VM runs.") }
        if !cli { return Row(on: on, enabled: false, note: nil) }
        return Row(on: on, enabled: true, note: vulkan ? nil : "Only with Vulkan: Graphics gives this VM OpenGL.")
    }
}
