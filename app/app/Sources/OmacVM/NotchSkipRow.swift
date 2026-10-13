import OmacVMFeatures
import SwiftUI

/// Skip the notch (NotchSkip: the VM folder's notch-skip, off by default), in
/// the Display card under Start in, on a Mac whose built-in display has a
/// notch. Its (i) shows what it does in a picture. While the VM runs, the
/// app passes a change on to it at once (Runner.watchNotchSkip).
struct NotchSkipRow: View {
    @ObservedObject var state: AppState
    /// The window pictures: the (i) open.
    var previewInfo = false
    @State private var on = false
    @State private var ready = true
    @State private var error: String?

    static let subtitle = "Bar items that don’t fit continue on the other side of the notch."
    static let info = "Off: items that don’t fit beside the notch go behind it. On: they continue on its other side, in the same order. They only hide when both sides are full. External displays keep their bar as it is."

    private var folder: URL { state.config.folder }

    var body: some View {
        SettingRow(title: "Skip the notch", subtitle: error ?? (on && !ready ? NotchSkip.notReady : Self.subtitle),
                   subtitleIsError: error != nil, probe: "notch-skip",
                   infoButton: AnyView(NotchSkipInfoButton(shown: previewInfo))) {
            RowSwitch(title: "Skip the notch", isOn: Binding(get: { on }, set: { set($0) }))
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
    }

    private func refresh() {
        on = NotchSkip.read(folder: folder)
        ready = NotchSkip.guestReady(folder: folder, features: try? String(
            contentsOf: folder.appendingPathComponent("features"), encoding: .utf8))
    }

    private func set(_ v: Bool) {
        guard v != on else { return }
        do {
            try NotchSkip.write(v, folder: folder)
            on = v
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// The (i) of Skip the notch: the picture and a few words, only on demand.
struct NotchSkipInfoButton: View {
    @State var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About Skip the notch")
        .help(NotchSkipRow.info)
        .popover(isPresented: $shown, arrowEdge: .bottom) { NotchSkipInfo() }
    }
}

struct NotchSkipInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSkipPicture()
            Text(NotchSkipRow.info)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 292, alignment: .leading)
        .padding(14)
    }
}
