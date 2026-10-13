import AppKit
import OmacVMFeatures
import OmacVMUpdate
import OmacVMWindow
import SwiftUI

// The rows of the VM window's sections (SettingsView.swift). Each reads and
// writes the setting it had before 3.1; state.tick (the window back in
// front, every few seconds) has them read it again.

// MARK: General

/// Resources: the create screen's tiers as one segmented row, the VM's CPUs
/// and memory as bars against the Mac's; Custom opens − / + for each, within
/// `omacvm resources`' limits (ResourceLimits). Written to vm.env at once,
/// as `omacvm resources` writes it.
struct ResourcesRow: View {
    @ObservedObject var state: AppState
    @State private var customOpen = false
    @State private var error: String?
    private let limits = ResourceLimits.mac
    private static let custom = 4

    private var tier: Int? { Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) }
    private var memoryGB: Int { state.config.memoryMB / 1024 }

    private var selection: Binding<Int> {
        Binding(get: { customOpen ? Self.custom : tier ?? Self.custom },
                set: { t in
                    if t == Self.custom {
                        customOpen = true
                    } else {
                        customOpen = false
                        let v = Mac.tier(t)
                        set(cpus: v.cpus, memoryGB: v.memoryGB)
                    }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                Text("Resources").frame(maxWidth: .infinity, alignment: .leading)
                Picker("Resources", selection: selection) {
                    ForEach(0..<4) { Text(Mac.tierNames[$0]).tag($0) }
                    Text("Custom").tag(Self.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help((0..<4).map { "\(Mac.tierNames[$0]): \(Mac.tier($0).cpus) CPUs, \(Mac.tier($0).memoryGB) GB" }.joined(separator: "\n"))
                .layoutProbe("trailing-resources")
            }
            HStack(spacing: 12) {
                Text("CPUs").font(.subheadline).frame(width: 56, alignment: .leading)
                CPUBar(total: Mac.cores, on: state.config.cpus)
                Text("\(state.config.cpus) of \(Mac.cores)").font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CPUs: \(state.config.cpus) of \(Mac.cores)")
            HStack(spacing: 12) {
                Text("Memory").font(.subheadline).frame(width: 56, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Look.track)
                        Capsule().fill(Color.accentColor)
                            .frame(width: g.size.width * min(1, Double(memoryGB) / Double(max(1, Mac.memoryGB))))
                    }
                }
                .frame(height: 8)
                Text("\(memoryGB) of \(Mac.memoryGB) GB").font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory: \(memoryGB) of \(Mac.memoryGB) GB")
            if customOpen || tier == nil {
                HStack(spacing: 24) {
                    ValueStepper(label: "CPUs", value: Binding(get: { state.config.cpus }, set: { set(cpus: $0, memoryGB: memoryGB) }),
                                 range: limits.cpus)
                    ValueStepper(label: "Memory", value: Binding(get: { memoryGB }, set: { set(cpus: state.config.cpus, memoryGB: $0) }),
                                 range: limits.memoryGB, unit: "GB", minWidth: 56)
                }
                .padding(.top, 1)
            }
            if let w = limits.warning(memoryGB: memoryGB) {
                Text(w).font(.subheadline).foregroundStyle(Look.orange).fixedSize(horizontal: false, vertical: true)
            }
            // A VM from a bigger Mac: what it starts with here (main.swift startVM).
            if let n = state.config.startSizeNote {
                Text(n).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = error { Text(e).font(.subheadline).foregroundStyle(Look.red) }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .onChange(of: state.config.folder) { _, _ in customOpen = false; error = nil }
    }

    private func set(cpus: Int, memoryGB: Int) {
        var c = state.config
        c.cpus = min(max(cpus, limits.cpus.lowerBound), limits.cpus.upperBound)
        c.memoryMB = min(max(memoryGB, limits.memoryGB.lowerBound), limits.memoryGB.upperBound) * 1024
        guard c != state.config else { return }
        do {
            try c.writeResources()
            state.config = c
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// One small block per CPU of the Mac; the VM's are in the accent colour.
struct CPUBar: View {
    let total: Int
    let on: Int

    var body: some View {
        HStack(spacing: total > 16 ? 2 : 3) {
            ForEach(0..<max(1, total), id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(i < on ? Color.accentColor : Look.track)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Graphics (Graphics.swift): the VM folder's `graphics` file, as `omacvm
/// graphics` and the control centre set it.
struct GraphicsRow: View {
    @ObservedObject var state: AppState
    @State private var choice = GraphicsChoice.auto
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        let plan = Runner.graphicsPlan(state.config)
        SettingRow(title: "Graphics", subtitle: error ?? note ?? "Next start: \(plan.summary).", subtitleIsError: error != nil,
                   info: GraphicsPicker.help, probe: "graphics") {
            // Vulkan fell back and stays off: choosing it again needs a button.
            if Graphics.fallback(folder: state.config.folder) != nil {
                Button("Try Vulkan Again") {
                    do {
                        try Graphics.write(choice, folder: state.config.folder)
                        state.tick += 1
                    } catch {
                        self.error = "Could not save: \(error.localizedDescription)"
                    }
                }
            }
            GraphicsPicker.picker($choice).labelsHidden().fixedSize()
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in note = nil; error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
        .onChange(of: choice) { _, v in write(v) }
    }

    private func refresh() {
        let g = Graphics.read(folder: state.config.folder)
        if g != choice { choice = g }
    }

    private func write(_ g: GraphicsChoice) {
        let folder = state.config.folder
        guard g != Graphics.read(folder: folder) else { return }
        do {
            try Graphics.write(g, folder: folder)
            error = nil
            let plan = Runner.graphicsPlan(state.config)
            note = g == .vulkan && !plan.venus
                ? "The VM has no Vulkan driver yet: it runs on OpenGL until `omacvm apply` (or `omacvm graphics` while the VM runs) builds it, a few minutes."
                : nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Closing the window (org.omacvm.app closeAction): what closing a running
/// VM's window does. QEMU gets it as OMACVM_CLOSE_ACTION.
struct CloseActionRow: View {
    var tick = 0
    @State private var action = Settings.closeAction

    var body: some View {
        SettingRow(title: "Closing the window", probe: "close") {
            Picker("Closing the window", selection: $action) {
                ForEach(CloseAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: action) { _, v in if v != Settings.closeAction { Settings.closeAction = v } }
        .onChange(of: tick) { _, _ in action = Settings.closeAction }
    }
}

// MARK: Display

/// Keep the Dock and hot corners away (org.omacvm.app keepDockAway, every VM).
struct KeepDockAwayRow: View {
    var tick = 0
    @State private var on = Settings.keepDockAway

    var body: some View {
        SettingRow(title: "Keep the Dock and hot corners away",
                   subtitle: "In full screen, the Dock and hot corners don’t pop up.", probe: "dock") {
            RowSwitch(title: "Keep the Dock and hot corners away", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.keepDockAway { Settings.keepDockAway = v } }
        .onChange(of: tick) { _, _ in on = Settings.keepDockAway }
    }
}

/// The escape combo (EscapeSetting: org.omacvm.gestures EscapeSwipe).
struct EscapeRow: View {
    var tick = 0
    @State private var choice = EscapeSetting.current()

    static let info = "In a full-screen VM, Control-Option-Esc moves the monitor under the pointer (or all monitors) to the Space beside the VM's with macOS's own animation; the VM stays full screen. Pressed in macOS, it goes back into the VM. The keyboard follows the pointer's monitor."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Escape combo (⌃⌥ Esc)")
                InfoButton(topic: "the escape combo", text: Self.info)
            }
            Text("Takes you back to macOS.").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 26) {
                PictureChoice(title: EscapeSetting.Choice.pointer.title, selected: choice == .pointer, width: 196) {
                    set(.pointer)
                } picture: { EscapePicture(all: false) }
                PictureChoice(title: EscapeSetting.Choice.all.title, selected: choice == .all, width: 196) {
                    set(.all)
                } picture: { EscapePicture(all: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .onChange(of: tick) { _, _ in choice = EscapeSetting.current() }
    }

    private func set(_ c: EscapeSetting.Choice) {
        choice = c
        EscapeSetting.set(c)
    }
}

// MARK: Input

/// Keyboard access: macOS's "control the computer" for OmacVM, which QEMU's
/// key tap needs (KeyAccess, KeyNote). Allowed: a green dot; not: Allow….
struct KeyboardRow: View {
    @ObservedObject var state: AppState
    /// The window pictures: this answer instead of the Mac's.
    var preview: KeyNote?
    @State private var keyNote = KeyNote.none

    static let allowedInfo = "Without this permission, ⌘ Tab, ⌘ Space and ⌘ ⇧ 4 go to macOS instead of Omarchy. macOS keeps it under Privacy & Security › Accessibility."

    var body: some View {
        SettingRow(title: "Keyboard access", subtitle: "Lets Mac shortcuts like ⌘Tab reach the VM.",
                   info: keyNote == .needsUser ? KeyAccess.missingText : Self.allowedInfo, probe: "keyboard") {
            if keyNote == .needsUser {
                HStack(spacing: 5) {
                    Circle().fill(Look.red).frame(width: 7, height: 7)
                    Text("Not allowed").font(.subheadline)
                }
                Button("Allow…") { KeyAccess.request { refreshKeyNote() } }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Look.green).frame(width: 7, height: 7)
                    Text("Allowed").font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear(perform: refreshKeyNote)
        .onChange(of: state.config.folder) { _, _ in refreshKeyNote() }
        .onChange(of: state.tick) { _, _ in refreshKeyNote() }
    }

    /// Checked again every few seconds and when OmacVM comes to the front
    /// (back from System Settings).
    private func refreshKeyNote() {
        keyNote = preview ?? KeyAccess.note(folder: state.config.folder)
        // Red: first clear an old "control the computer" entry (KeyAccess.reset).
        if keyNote == .needsUser, preview == nil {
            KeyAccess.clearOldEntryOnce { refreshKeyNote() }
        }
    }
}

/// Swipe out to macOS (org.omacvm.gestures SwipeOut, off by default): past
/// the first or the last workspace, a swipe goes on to the macOS Space beside
/// the VM. OmacVM Gestures reads it.
struct SwipeOutRow: View {
    var tick = 0
    /// This VM has trackpad gestures off: nothing to swipe with there.
    var gesturesOff = false
    @State private var on = SwipeOutSetting.current()

    var body: some View {
        SettingRow(title: "Swipe out to macOS",
                   subtitle: "Swipe past the first or last workspace to the macOS Space beside it."
                       + (gesturesOff ? " Trackpad gestures are off in this VM." : ""), probe: "swipe-out") {
            SwipeOutPicture()
            RowSwitch(title: "Swipe out to macOS", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != SwipeOutSetting.current() { SwipeOutSetting.set(v) } }
        .onChange(of: tick) { _, _ in on = SwipeOutSetting.current() }
    }
}

/// A feature the VM's record (its folder's `features`) has off.
enum VMRecord {
    static func isOff(_ feature: String, folder: URL) -> Bool {
        let text = (try? String(contentsOf: folder.appendingPathComponent("features"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).contains { $0 == "\(feature)=off" }
    }
}

// MARK: Sharing & Devices

/// One folder of the Mac at ~/Mac in the VM (MacFolder, the VM folder's
/// mac-folder file), off by default. Switching it on asks for the folder.
struct MacFolderRow: View {
    @ObservedObject var state: AppState
    @State private var path: String?
    @State private var error: String?

    var body: some View {
        SettingRow(title: "Mac folder",
                   subtitle: error ?? path.map { "\(StorageModel.short(URL(fileURLWithPath: $0))) appears at ~/Mac in the VM." }
                       ?? "Share one folder of the Mac at ~/Mac in the VM.",
                   subtitleIsError: error != nil,
                   info: "The VM can read and change everything in that folder.", probe: "mac-folder") {
            if path != nil {
                Button("Choose…") { if let url = MacFolder.choose(current: path) { set(url) } }
            }
            RowSwitch(title: "Mac folder", isOn: Binding(get: { path != nil }, set: { on in
                if !on { set(nil) } else if let url = MacFolder.choose(current: path) { set(url) }
            }))
        }
        .help(path ?? "")
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
    }

    private func refresh() { path = MacFolder.path(state.config) }

    private func set(_ url: URL?) {
        do {
            try MacFolder.set(url, for: state.config)
            error = nil
        } catch {
            self.error = "Could not share: \(error.localizedDescription)"
        }
        refresh()
    }
}

/// The fast network (experimental): a switch, never automatic. Turning it
/// on installs a small system service, so macOS asks for the password once.
struct FastNetworkRow: View {
    @ObservedObject var state: AppState
    @State private var on = false
    @State private var busy = false
    @State private var error: String?
    @State private var status = ""
    /// The service needs the person (FastNetwork.serviceNeeds): its button.
    @State private var fix: String?

    static let info = "Off: QEMU's own network. On: macOS's VM network (as Parallels and UTM), faster to and from the Mac; macOS asks for your password once."

    var body: some View {
        SettingRow(title: "Fast network", badge: "experimental",
                   subtitle: error ?? (status.isEmpty ? "macOS's VM network, faster to and from the Mac." : status),
                   subtitleIsError: error != nil, info: Self.info, probe: "fast-network") {
            if busy { ProgressView().controlSize(.small) }
            if let fix, on { Button(fix) { update() }.disabled(busy) }
            RowSwitch(title: "Fast network", isOn: Binding(get: { on }, set: { v in if v != on { toggle() } }), enabled: !busy)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        // Every few seconds only the switch's file; the service's check (it
        // reads QEMU's whole binary) when it changed.
        .onChange(of: state.tick) { _, _ in if !busy && FastNetwork.isOn(state.config) != on { refresh() } }
    }

    /// The line under the switch, worked out off the main thread (the service
    /// check verifies QEMU's code signature, which reads the whole binary).
    /// Off says nothing: the line says what it is. The service is checked as
    /// the installer checks it (an older build of the same protocol is fine;
    /// another protocol after an app update needs an update): its button
    /// then, Update… or Install….
    nonisolated static func status(_ c: VMConfig) -> (on: Bool, text: String, fix: String?) {
        guard FastNetwork.isOn(c) else { return (false, "", nil) }
        let status = FastNetwork.serviceStatus()
        if status == "stopped" { return (true, "On, but \(FastNetwork.stoppedText); until then the VM starts on the normal network.", nil) }
        if let need = FastNetwork.serviceNeeds(status) {
            return (true, "On. \(need.why) \(need.button) fixes it and asks for your password once.", need.button)
        }
        if let why = FastNetwork.serviceProblem() { return (true, "On, but \(why): switch it off, then on again.", nil) }
        return (true, "", nil)
    }

    private func refresh() {
        let c = state.config
        on = FastNetwork.isOn(c)
        Task.detached {
            let st = Self.status(c)
            await MainActor.run { show(st) }
        }
    }

    private func show(_ st: (on: Bool, text: String, fix: String?)) {
        on = st.on
        status = st.text
        fix = st.fix
    }

    private func toggle() {
        let c = state.config, turnOn = !on
        // A VM of this app that runs on the fast network keeps it until it shuts down.
        let inUse = state.vmRunning() && FastNetwork.lastRecord(c) == "vmnet"
        busy = true
        error = nil
        Task.detached {
            let err = turnOn ? FastNetwork.turnOn(c) : FastNetwork.turnOff(c, vmnetInUse: inUse)
            let st = Self.status(c)
            await MainActor.run {
                busy = false
                error = err
                show(st)
            }
        }
    }

    /// Update… / Install…: the service for this app (macOS's password dialog).
    private func update() {
        let c = state.config
        busy = true
        error = nil
        Task.detached {
            let err = FastNetwork.updateService()
            let st = Self.status(c)
            await MainActor.run {
                busy = false
                error = err
                show(st)
            }
        }
    }
}

// MARK: Storage & Updates

/// The weekly-check switch (shared with the control centre), Check Now and
/// what the last check found.
struct UpdateRow: View {
    @ObservedObject var updater: Updater
    /// A VM runs from this app: the update waits for its shutdown.
    var running = false

    private var line: String {
        if let v = updater.downloading { return Self.downloadLine(v, updater.downloaded) }
        if updater.checking { return "Checking…" }
        if let s = updater.staged { return "\(Product.name) \(s.version) is ready to install." }
        if let o = updater.lastOutcome, let l = Updater.outcomeLine(o, current: updater.currentVersion) { return l }
        if !updater.enabled { return "Off: no checks and no messages. Check Now still works." }
        guard Version(updater.currentVersion) != nil else { return "Check Now looks for a newer version." }
        if let d = updater.lastCheckDate { return "Checked \(Self.when(d)). \(Product.name) \(updater.currentVersion) is the newest version." }
        return "You have \(Product.name) \(updater.currentVersion)."
    }

    /// "Downloading OmacVM 3.1.4… 12.3 of 34.8 MB" (nothing yet: no numbers).
    static func downloadLine(_ version: String, _ progress: (done: Int64, total: Int64)?) -> String {
        let head = "Downloading \(Product.name) \(version)…"
        guard let p = progress, p.done > 0, p.total > 0 else { return head }
        return head + String(format: " %.1f of %.1f MB", Double(min(p.done, p.total)) / 1e6, Double(p.total) / 1e6)
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        let s = f.string(from: d)
        // "Today at 14:02" -> "today at 14:02"
        return Calendar.current.isDateInToday(d) || Calendar.current.isDateInYesterday(d) ? s.prefix(1).lowercased() + s.dropFirst() : "on \(s)"
    }

    var body: some View {
        SettingRow(title: "Check for updates once a week", subtitle: line,
                   info: "Off: no checks and no messages. Check Now still works. The same switch as in the control centre in Omarchy.",
                   probe: "updates") {
            if updater.checking { ProgressView().controlSize(.small) }
            if updater.staged != nil && !updater.installWhenIdle && !updater.restarting {
                // The same button as the banner, also here.
                Button(UpdateBanner.updateTitle(running: running)) { UpdateBanner.update(updater) }
                    .layoutProbe("row-update-now")
            } else {
                Button("Check Now") { Task { await updater.checkNow() } }
                    .disabled(updater.checking || updater.restarting)
            }
            RowSwitch(title: "Check for updates once a week", isOn: Binding(get: { updater.enabled }, set: { updater.setEnabled($0) }))
        }
    }
}
