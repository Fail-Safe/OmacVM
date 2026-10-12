import AppKit
import OmacVMFeatures
import SwiftUI

/// "Start in" in the VM window: Window, Full screen (notch via Omanotch) or,
/// on a Mac whose built-in display has a notch now, Full screen including
/// notch (FullPanel, #339), as pictures. One choice for two settings: the
/// app's startFullScreen (every VM) and this VM's notch-mode (StartIn). The
/// same notch-mode as `omacvm notch` / `omacvm fullscreen` and the control
/// centre's Full screen row.
struct StartInRow: View {
    @ObservedObject var state: AppState
    /// The window pictures: as on a Mac with or without a notch.
    var previewNotch: Bool?
    @State private var fullScreen = Settings.startFullScreen
    @State private var mode = NotchMode.native
    @State private var hasNotch = false
    @State private var ready = false
    @State private var error: String?

    private var folder: URL { state.config.folder }
    private var current: StartIn { StartIn.current(fullScreen: fullScreen, mode: mode, hasNotch: hasNotch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start in").fontWeight(.semibold)
            HStack(alignment: .top, spacing: 12) {
                ForEach(StartIn.choices(hasNotch: hasNotch), id: \.self) { c in
                    PictureChoice(title: c.caption, subtitle: c.detail(hasNotch: hasNotch), selected: c == current, width: 164) {
                        set(c)
                    } picture: {
                        StartInPicture(kind: Self.kind(c), notch: hasNotch)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            if let n = note {
                Text(n.text).font(.subheadline).foregroundStyle(n.error ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .onAppear { refresh() }
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = previewNotch ?? Mac.hasNotch
        }
    }

    static func kind(_ c: StartIn) -> StartInPicture.Kind {
        switch c {
        case .window: return .window
        case .fullScreen: return .fullScreen
        case .fullScreenNotch: return .fullScreenNotch
        }
    }

    /// Under the pictures: what keeps "including notch" from working, a
    /// failed save, or what it is.
    private var note: (text: String, error: Bool)? {
        if let error { return (error, true) }
        guard current == .fullScreenNotch else { return nil }
        if !ready { return (NotchArea.notReady, false) }
        if !Settings.keepDockAway && Self.menuBarAlwaysShown {
            return ("macOS shows the menu bar in full screen (Control Center settings), so the VM starts below it. Keep the Dock and hot corners away hides it.", false)
        }
        return (StartIn.notchNote, false)
    }

    /// macOS's "Automatically hide and show the menu bar: never" in full
    /// screen (#356). With Keep the Dock away on, QEMU's immersive full screen
    /// hides it anyway (b-3018); without, the VM starts below it.
    static var menuBarAlwaysShown: Bool {
        UserDefaults.standard.object(forKey: "AppleMenuBarVisibleInFullscreen") as? Bool ?? false
    }

    private func refresh() {
        fullScreen = Settings.startFullScreen
        mode = NotchArea.read(folder: folder)
        hasNotch = previewNotch ?? Mac.hasNotch
        ready = NotchArea.guestReady(folder: folder, features: try? String(
            contentsOf: folder.appendingPathComponent("features"), encoding: .utf8))
    }

    private func set(_ c: StartIn) {
        guard c != current else { return }
        if let m = c.mode, m != mode {
            do {
                try NotchArea.write(m, folder: folder)
                mode = m
            } catch {
                self.error = "Could not save: \(error.localizedDescription)"
                return
            }
        }
        error = nil
        fullScreen = c.fullScreen
        Settings.startFullScreen = c.fullScreen
    }
}
