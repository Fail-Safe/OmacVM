// Draws OmacVM.app's "Magic Mouse swipe" row with and without a Magic Mouse
// (MagicMouse.override), alone and in the setup and VM windows, to PNGs
// (light and dark), without a window on screen: src/tests/app-mouse-swipe.sh.
import AppKit
import SwiftUI

@MainActor
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.0)) }

@MainActor
func draw<V: View>(_ root: V, _ name: String, _ out: URL, width: CGFloat? = nil) -> CGSize {
    var size = CGSize.zero
    for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
        let view = NSHostingView(rootView: root.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: look)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 200), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: look)
        w.contentView = view
        view.setFrameSize(view.fittingSize)
        settle()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        size = view.bounds.size
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
        }
    }
    print("drawn \(name) \(Int(size.width))x\(Int(size.height))")
    return size
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    var fail = false
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "ok  " : "FAIL") \(what)"); if !ok { fail = true } }

    // The watch follows the mouse coming and going.
    MagicMouse.override = false
    let watch = MagicMouseWatch()
    MagicMouse.override = true
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))
    check(watch.connected, "watch: a Magic Mouse connected later shows within 3 s")
    MagicMouse.override = false
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))
    check(!watch.connected, "watch: switched off: gone within 3 s")
    let row = draw(Card { MagicMouseRow() }.padding(8), "row", out, width: 552)
    check(row.height >= 30, "row: label, picker and (i) drawn (\(Int(row.height)) pt)")

    // The whole window (tall enough for every row): the row is there with a
    // Magic Mouse, not without.
    LayoutProbe.on = true
    let state = AppState()
    state.storage.refresh(); settle()
    for (mouse, tag) in [(true, "mouse"), (false, "no-mouse")] {
        MagicMouse.override = mouse
        state.screen = .ready
        RenderVMWindow.picture("ready-\(tag)", into: out, height: 2600) { RootView(state: state) }
        let inReady = LayoutProbe.frames["trailing-magic-mouse"] != nil
        state.screen = .setup
        RenderVMWindow.picture("setup-\(tag)", into: out, height: 2600) { RootView(state: state) }
        let inSetup = LayoutProbe.frames["trailing-magic-mouse"] != nil
        check(inReady == mouse, "VM window: the row \(mouse ? "shows with" : "is gone without") a Magic Mouse")
        check(inSetup == mouse, "setup: the row \(mouse ? "shows with" : "is gone without") a Magic Mouse")
    }
    exit(fail ? 1 : 0)
}
