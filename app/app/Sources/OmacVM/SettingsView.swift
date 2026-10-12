import AppKit
import OmacVMDesktop
import OmacVMFeatures
import OmacVMWindow
import SwiftUI

/// The VM window before Start (docs/design/settings-3.1): the header with
/// the VM and Start, the update banner, and the VM's settings in five
/// sections with the sidebar. Every row reads and writes the same setting as
/// before 3.1 (AGENTS.md, "Settings"), so an update keeps every choice; what
/// `omacvm` or the control centre changed shows when the window comes back
/// to the front.
struct ReadyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared
    /// The window pictures (--render-vm-window): this keyboard note and this
    /// "omacvm in Terminal" state instead of the Mac's, and more.
    var preview: RenderVMWindow.Preview? = nil
    @State private var sheet: ReadySheet?
    /// The VM to delete runs (or omacvm works on it): asked once, when the sheet opens.
    @State private var deleteBusy = false

    enum ReadySheet: Identifiable {
        case delete(VMConfig), whatsNew
        var id: String {
            switch self {
            case .delete(let c): return "delete-" + c.folder.path
            case .whatsNew: return "whats-new"
            }
        }
    }

    private var running: Bool { preview?.running ?? state.vmRunning() }

    var body: some View {
        WindowShell(nav: SettingsNav.items) {
            header
        } notices: {
            UpdateBanner(updater: updater, running: running) { sheet = .whatsNew }
            notices
        } content: {
            SettingsSections(state: state, preview: preview, running: running) { vm in
                deleteBusy = preview?.running ?? !Storage.busyFolders([vm.folder]).isEmpty
                sheet = .delete(vm)
            }
        }
        .environment(\.spyStart, preview?.section)
        .sheet(item: $sheet) { s in
            switch s {
            case .delete(let vm):
                DeleteSheet(vm: vm, size: state.storage.vms.first { $0.folder.path == vm.folder.path }?.size,
                            running: deleteBusy) { delete in
                    sheet = nil
                    if delete { state.storage.trash(vm) }
                }
            case .whatsNew:
                WhatsNewSheet(updater: updater, running: running) { sheet = nil }
            }
        }
        .onAppear { if let s = preview?.sheet { sheet = s } }
        // `omacvm`, the control centre or another window may have changed a
        // setting meanwhile: read them again (every row follows state.tick).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.reloadSettings()
        }
        .task {
            while !Task.isCancelled && preview == nil {
                try? await Task.sleep(for: .seconds(3))
                // Only while the window shows (not while a VM runs and it is put away).
                if NSApp.windows.contains(where: { $0.isVisible && $0.contentViewController is NSHostingController<RootView> }) {
                    state.reloadSettings()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        WindowHeader(title: state.config.name,
                     pill: running ? StatusPill(text: "Running", dot: Look.green) : StatusPill(text: "Stopped"),
                     facts: "\(state.config.cpus) CPUs · \(state.config.memoryMB / 1024) GB memory · \(state.config.diskGB) GB disk"
                         + (state.config.user.isEmpty ? "" : " · user \(state.config.user)"),
                     factsInfo: factsInfo) {
            AppIconButton()
        } trailing: {
            if let app = preview?.appVersion ?? OmacVMVersion.app, OmacVMVersion.vmIsBehind(state.config.guestVersion, app: app) {
                Button {
                    updateVM()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Look.orange).frame(width: 6, height: 6)
                        Text("Update VM")
                    }
                }
                .help("OmacVM in this VM is \(state.config.guestVersion.map { "\($0)" } ?? "from an older app"); this app has \(app). Update VM starts the VM without a window, updates OmacVM in it and its helpers on the Mac (a few minutes) and shuts it down. Your files and settings in Omarchy stay.")
                .disabled(state.storage.moving != nil || state.config.filesProblem != nil || running)
                .layoutProbe("update-vm")
            }
            Button(running ? "Show" : "Start") {
                if running { state.showVM() } else { state.startVM() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!running && (state.storage.moving != nil || state.config.filesProblem != nil))
            .layoutProbe("start")
        }
    }

    /// The VM's memory and its graphics memory side by side: the VM's RAM is
    /// fixed, its graphics come from the Mac on top, as needed (GPUMemory).
    private var factsInfo: String {
        let gpu = GPUMemory.read(for: state.config).map {
            "Graphics memory last run: peak \(GPUMemory.gb($0.peakMB)), from the Mac on top."
        } ?? "Graphics memory comes from the Mac on top, as the VM needs it."
        return "Set when the VM was made. CPUs and memory change under General, the disk under Storage. \(gpu)\n\n\(GPUMemory.explanation)"
    }

    /// A VM made by an older app keeps its OmacVM when the app is replaced:
    /// Update VM brings it up to this app's.
    private func updateVM() {
        // A test build never updates a VM of the installed app.
        if let why = Paths.startProblem(state.config.folder) { state.say(why); return }
        // Not shut down cleanly, or copied while it ran: asked first.
        guard RunMarker.confirmStart(state.config) else { return }
        state.message = nil
        state.creator.update(config: state.config)
        state.screen = .building
    }

    // MARK: Notices under the header

    @ViewBuilder private var notices: some View {
        // While an update waits for the VM, the banner says so already.
        if let n = updater.notice, !(updater.staged != nil && updater.installWhenIdle) {
            MessageStrip(text: n) { updater.notice = nil }
        }
        if let m = state.message {
            MessageStrip(text: m, error: !state.messageIsInfo) { state.message = nil }
        }
        if let p = state.config.filesProblem {
            MessageStrip(text: p, error: true)
        }
    }
}

extension EnvironmentValues {
    /// The window pictures: the section the settings start scrolled to.
    @Entry var spyStart: String? = nil
}

/// The five sections: General, Display, Input, Sharing & Devices, Storage & Updates.
struct SettingsSections: View {
    @ObservedObject var state: AppState
    var preview: RenderVMWindow.Preview?
    var running: Bool
    var delete: (VMConfig) -> Void
    @StateObject private var mouse = MagicMouseWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "General", first: true)
            Card {
                ResourcesRow(state: state)
                GraphicsRow(state: state)
                CloseActionRow(tick: state.tick)
            }
        }
        .spySection("general")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Display")
            Card {
                StartInRow(state: state, previewNotch: preview?.notch)
                KeepDockAwayRow(tick: state.tick)
                EscapeRow(tick: state.tick)
                if preview?.magicMouse ?? mouse.connected {
                    MagicMouseRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
                }
            }
        }
        .spySection("display")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Input")
            Card {
                KeyboardRow(state: state, preview: preview?.keyNote)
                MacIMERow(state: state)
                SwipeOutRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
            }
        }
        .spySection("input")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Sharing & Devices")
            Card {
                MacFolderRow(state: state)
                USBRow(state: state)
                FastNetworkRow(state: state)
            }
        }
        .spySection("sharing")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Storage & Updates")
            Card {
                DiskRow(state: state, preview: preview?.disk)
                StorageRows(storage: state.storage, selected: state.config.location == nil ? nil : state.config.folder,
                            open: { state.openExisting() }, delete: delete)
                CommandLineRow(preview: preview?.terminal)
                UpdateRow(updater: Updater.shared)
            }
            ForEach(state.storage.disconnected, id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(Look.red).padding(.top, 8).padding(.horizontal, 4)
            }
            if let n = state.storage.note {
                Text(n).font(.subheadline).foregroundStyle(state.storage.noteIsError ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 8).padding(.horizontal, 4)
            }
            Button("Delete VM…") { delete(state.config) }
                .buttonStyle(.plain)
                .foregroundStyle(Look.red)
                .disabled(state.storage.moving != nil)
                .padding(.top, 14)
                .padding(.leading, 4)
                .layoutProbe("delete")
        }
        .spySection("storage")
    }
}
