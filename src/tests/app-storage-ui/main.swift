// Renders OmacVM.app's storage screens to PNGs (light and dark) without a
// window on screen, from a fixture home: src/tests/app-storage-ui.sh.
import AppKit
import SwiftUI

@MainActor
func render(_ state: AppState, _ name: String, _ out: URL) {
    // The app's window as it opens, tall enough for every row.
    RenderVMWindow.picture(name, into: out, height: 1800) { RootView(state: state) }
    print("rendered \(name).png and \(name)-dark.png")
}

/// A view of its own (the All VMs sheet), light and dark.
@MainActor
func render<V: View>(_ name: String, _ out: URL, _ content: () -> V) {
    for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
        let view = NSHostingView(rootView: content().background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: look)
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
        print("rendered \(name)\(suffix).png \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}

/// An alert's window, as the app shows it (never on screen here).
@MainActor
func render(_ alert: NSAlert, _ name: String, _ out: URL) {
    for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
        alert.window.appearance = NSAppearance(named: look)
        alert.layout()
        guard let view = alert.window.contentView else { continue }
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
        print("rendered \(name)\(suffix).png \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}

@MainActor
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    let state = AppState()
    state.storage.refresh(); settle()
    render(state, "1-ready-two-folders", out)
    render("7-all-vms", out) { AllVMsView(storage: state.storage, selected: state.config.folder) {} }
    render(state.storage.removeImagesAlert(), "8-remove-images", out)
    render("9-delete-vm", out) { DeleteSheet(vm: VMConfig.named("Work")!, size: nil, running: false) { _ in } }

    Paths.otherVMsRoots = [URL(fileURLWithPath: "/Volumes/SD4TB-not-here/OmacVM")]
    state.storage.refresh(); settle()
    render(state, "2-ready-drive-not-connected", out)

    state.storage.moving = StorageModel.Moving(name: "Omarchy", phase: "Copying", done: 12_400_000_000, total: 41_000_000_000)
    render(state, "3-moving", out)
    state.storage.moving = nil

    state.config.location = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("OmacVM/Omarchy")
    try? FileManager.default.removeItem(at: state.config.folder.appendingPathComponent("efi-vars.fd"))
    state.storage.note = "Moved 1 VM to ~/OmacVM."
    render(state, "4-files-missing", out)

    Paths.vmsRoot = URL(fileURLWithPath: "/Volumes/SD4TB-not-here/OmacVM")
    state.screen = .driveMissing
    render(state, "5-drive-not-connected", out)

    Paths.vmsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("OmacVM")
    state.storage.note = nil
    state.screen = .setup
    state.storage.refresh(); settle()
    render(state, "6-setup", out)
}
