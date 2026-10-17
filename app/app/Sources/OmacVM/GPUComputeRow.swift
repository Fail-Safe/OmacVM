import Foundation
import OmacVMFeatures
import SwiftUI

/// WebGPU and GPU compute (feature gpu-compute, on by default) in the VM
/// window's General section, under Graphics: one switch, the same feature as
/// in the control centre and `omacvm enable/disable gpu-compute`. Its part is
/// in the VM (OpenCL's switch, the "Chromium (WebGPU)" entry, Firefox's
/// WebGPU), so it switches while the VM runs; Vulkan stays as Graphics says.
struct GPUComputeRow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var busy = false
    @State private var note: String?

    static let info = "OpenCL apps (darktable, ffmpeg's OpenCL filters, Geekbench GPU) and WebGPU (Firefox, and Chromium from its “Chromium (WebGPU)” menu entry) run on the Mac's GPU while Graphics gives the VM Vulkan (Automatic does on macOS 26 and newer). WebGPU lets web pages run their own GPU code. Off removes OpenCL's switch, the menu entry and Firefox's WebGPU; Vulkan stays as Graphics says."

    var body: some View {
        let running = state.vmRunning()
        let vulkan = Runner.graphicsPlan(state.config).venus
        let row = GPUCompute.row(record: record, running: running, vulkan: vulkan, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "WebGPU and GPU compute", subtitle: n, subtitleIsError: n?.hasPrefix("Could not") == true,
                   info: Self.info, probe: "gpu-compute") {
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "WebGPU and GPU compute", isOn: Binding(get: { row.on }, set: { v in if v != row.on { run(v) } }),
                      enabled: row.enabled)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        .onChange(of: state.tick) { _, _ in if !busy { refresh() } }
        .onChange(of: running) { _, _ in note = nil; refresh() }
    }

    private func refresh() {
        record = try? String(contentsOf: state.config.folder.appendingPathComponent("features"), encoding: .utf8)
    }

    /// `omacvm enable|disable gpu-compute` for this running VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = MacIMERow.run([value ? "enable" : "disable", GPUCompute.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = value ? "On: OpenCL for apps started after the next login." : nil }
            }
        }
    }
}
