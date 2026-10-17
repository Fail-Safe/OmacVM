import Foundation
import OmacVMFeatures
import SwiftUI

/// WebGPU and GPU compute (feature gpu-compute, on by default) in the VM
/// window's General section, under Graphics: one switch, the same feature as
/// in the control centre and `omacvm enable/disable gpu-compute`. Its part is
/// in the VM (OpenCL's switch, the "Chromium (WebGPU)" entry, Firefox's
/// WebGPU); Vulkan stays as Graphics says. While the VM runs it runs this
/// app's omacvm for the VM; while it is stopped (the usual case: the window
/// hides while a VM it started runs) it writes the choice into the VM's record
/// and a pending file, and the app sets up the VM's part at the next start
/// (FeatureStart).
struct GPUComputeRow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    static let info = "OpenCL apps (darktable, ffmpeg's OpenCL filters, Geekbench GPU) and WebGPU (Firefox, and Chromium from its “Chromium (WebGPU)” menu entry) run on the Mac's GPU while Graphics gives the VM Vulkan (Automatic does on macOS 26 and newer). WebGPU lets web pages run their own GPU code. Off removes OpenCL's switch, the menu entry and Firefox's WebGPU; Vulkan stays as Graphics says."

    var body: some View {
        let running = state.vmRunning()
        let vulkan = Runner.graphicsPlan(state.config).venus
        let row = GPUCompute.row(record: record, pending: pending, running: running, vulkan: vulkan, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "WebGPU and GPU compute", subtitle: n, subtitleIsError: n?.hasPrefix("Could not") == true,
                   info: Self.info, probe: "gpu-compute") {
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "WebGPU and GPU compute", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
                      enabled: row.enabled)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        .onChange(of: state.tick) { _, _ in if !busy { refresh() } }
        .onChange(of: running) { _, _ in note = nil; refresh() }
        .onReceive(NotificationCenter.default.publisher(for: FeatureStart.done)) { _ in refresh() }
    }

    private func refresh() {
        let f = state.config.folder
        record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        pending = try? String(contentsOf: f.appendingPathComponent(GPUCompute.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        let f = state.config.folder
        let next = GPUCompute.switchState.switchStopped(record: record, pending: pending, on: value)
        let pendingURL = f.appendingPathComponent(GPUCompute.pendingFile)
        do {
            try next.record.write(to: f.appendingPathComponent("features"), atomically: true, encoding: .utf8)
            if let p = next.pending { try p.write(to: pendingURL, atomically: true, encoding: .utf8) }
            else if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
            note = nil
        } catch {
            note = "Could not switch: \(error.localizedDescription)"
        }
        refresh()
    }

    /// `omacvm enable|disable gpu-compute` for this running VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = MacIMERow.run([value ? "enable" : "disable", GPUCompute.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            // Switched now: nothing left for the next start.
            if err == nil { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(GPUCompute.pendingFile)) }
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = value ? "On: OpenCL for apps started after the next login." : nil }
            }
        }
    }
}
