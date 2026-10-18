import Foundation

/// WebGPU and GPU compute on the VM's Vulkan (feature gpu-compute, on by
/// default; src/app/guest/venus/compute.sh): OpenCL, the "Chromium (WebGPU)"
/// entry and Firefox's WebGPU while the VM's Graphics gives it Vulkan. The
/// VM window's row switches it: while the VM runs with `omacvm
/// enable|disable gpu-compute`, while it is stopped into the record and a
/// pending file, set up in the VM at its next start (PendingSwitch; the
/// window hides while a VM it started runs, so stopped is the usual case).
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public enum GPUCompute {
    public static let feature = "gpu-compute"
    public static let switchState = PendingSwitch(feature: feature, defaultOn: true)
    public static var pendingFile: String { switchState.pendingFile }

    /// The record's word for it. On by default: a record without the word
    /// (a VM from before 3.1.20, or none yet) is on, as apply will make it.
    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    /// The row: on or off (a pending choice over the record), whether it can
    /// be switched now, and its note.
    public struct Row: Equatable {
        public var on: Bool
        public var enabled: Bool
        public var note: String?
        public init(on: Bool, enabled: Bool, note: String?) { self.on = on; self.enabled = enabled; self.note = note }
    }

    /// `vulkan`: the VM's next start has Vulkan (Graphics). Stopped: written
    /// down for the next start. Running: `omacvm enable|disable`.
    public static func row(record: String?, pending text: String?, running: Bool, vulkan: Bool, busy: Bool, cli: Bool) -> Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        let gl = vulkan ? nil : "Only with Vulkan: Graphics gives this VM OpenGL."
        if busy { return Row(on: on, enabled: false, note: nil) }
        if !running { return Row(on: on, enabled: true, note: gl) }
        return Row(on: on, enabled: cli, note: p == nil ? gl : "Being set up in the VM for this start.")
    }
}
