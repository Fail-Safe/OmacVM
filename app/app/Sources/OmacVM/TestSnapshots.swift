import AppKit
import OmacVMUpdate

/// Test builds only: OMACVM_TEST_SNAPSHOTS=DIR. The distributed notification
/// "<bundle id>.snapshot" with a name as its object draws each visible window
/// of the app (the VM window, a sheet on it, a popover) into DIR/NAME-N.png as
/// it is on screen, in its real appearance, without a screen recording
/// permission (each window draws itself). For the human-like checks of the
/// running app (work/tracks/lane-w.md).
@MainActor
enum TestSnapshots {
    static var dir: URL?

    static func start() {
        guard let d = TestHooks.value("OMACVM_TEST_SNAPSHOTS", bundleID: Bundle.main.bundleIdentifier) else { return }
        dir = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: d), withIntermediateDirectories: true)
        let name = Notification.Name("\(Bundle.main.bundleIdentifier ?? "omacvm").snapshot")
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let tag = (note.object as? String).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? "shot"
            MainActor.assumeIsolated { take(tag) }
        }
    }

    static func take(_ tag: String) {
        guard let dir else { return }
        var i = 0
        for w in NSApp.windows where w.isVisible {
            guard let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let kind = w.isSheet ? "sheet" : (w.className.contains("Popover") ? "popover" : "window")
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(tag)-\(i)-\(kind).png"))
            i += 1
        }
    }
}
