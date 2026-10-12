import SwiftUI

/// Whether a Magic Mouse is connected, looked for every few seconds while a
/// window shows it, so one connected or switched off later shows or hides
/// the row.
@MainActor
final class MagicMouseWatch: ObservableObject {
    @Published private(set) var connected = MagicMouse.connected()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let c = MagicMouse.connected()
        if c != connected { connected = c }
    }
}

/// "Magic Mouse swipe" (MouseSwipeSetting: org.omacvm.gestures
/// MouseSwipeFingers), a row in the setup's and the VM window's cards; they
/// show it only while MagicMouseWatch sees a Magic Mouse.
struct MagicMouseRow: View {
    var tick = 0
    /// The shown VM has trackpad gestures off (the setup: they are switched off there).
    var gesturesOff = false
    @State private var fingers = MouseSwipeSetting.current()

    var body: some View {
        SettingRow(title: "Magic Mouse swipe",
                   subtitle: "Two fingers on the mouse act as this many on a trackpad." + (gesturesOff ? " Trackpad gestures are off in this VM." : ""),
                   info: MouseSwipeSetting.hint, probe: "magic-mouse") {
            Picker("Magic Mouse swipe", selection: $fingers) {
                ForEach(MouseSwipeSetting.choices, id: \.self) { Text("\($0) fingers").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: fingers) { _, v in if v != MouseSwipeSetting.current() { MouseSwipeSetting.set(v) } }
        .onChange(of: tick) { _, _ in fingers = MouseSwipeSetting.current() }
    }
}
