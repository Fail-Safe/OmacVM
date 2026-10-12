import Foundation

/// The app's window (docs/design/settings-3.1): 800 pt wide, a sidebar of
/// 200 pt and the content beside it. Only the height can change (500 pt at
/// least); it opens as tall as the screen shows below the menu bar and above
/// the Dock, less a margin, so as many settings as possible are in view. The
/// settings scroll inside it.
public enum WindowSize {
    public static let width: Double = 800
    public static let sidebar: Double = 200
    public static let minHeight: Double = 500
    /// Kept free above and below the window on its screen.
    public static let margin: Double = 16

    /// A 13-inch MacBook Air at its default resolution, with the menu bar and
    /// the Dock, shows about this much: the window pictures are drawn at its
    /// default height and must fit it (`OmacVM --render-vm-window`).
    public static let smallScreenVisible: Double = 792

    /// The height the window opens with on a screen whose visible frame is
    /// `visible` tall.
    public static func defaultHeight(visible: Double) -> Double {
        max(minHeight, (visible - 2 * margin).rounded(.down))
    }
}

/// Which section the sidebar marks while the settings scroll: the last one
/// whose top has reached `threshold` below the top of the visible part, and
/// the last one once the list is scrolled to its end (a short last section
/// never reaches the threshold).
public enum ScrollSpy {
    public static let threshold: Double = 90

    /// - tops: each section's top, in points below the top of the visible part
    ///   (negative once scrolled past).
    /// - atEnd: the list is scrolled to its end.
    public static func current(tops: [Double], atEnd: Bool, threshold: Double = threshold) -> Int {
        guard !tops.isEmpty else { return 0 }
        if atEnd { return tops.count - 1 }
        var i = tops.count - 1
        while i > 0 && tops[i] > threshold { i -= 1 }
        return i
    }

    /// Scrolled to the end, give or take a few points.
    public static func atEnd(offset: Double, visible: Double, content: Double) -> Bool {
        content > visible && offset + visible >= content - 4
    }
}

/// "Closing the window" (org.omacvm.app closeAction): what closing a running
/// VM's window does. The window stores it; QEMU gets it as
/// OMACVM_CLOSE_ACTION. Anything else than the three words is the default.
public enum CloseAction: String, CaseIterable, Sendable {
    case shutdown, keepRunning, ask

    public static let key = "closeAction"
    public static let defaultValue = CloseAction.shutdown

    public static func parse(_ stored: Any?) -> CloseAction {
        (stored as? String).flatMap(CloseAction.init(rawValue:)) ?? defaultValue
    }

    public var title: String {
        switch self {
        case .shutdown: return "Shut down"
        case .keepRunning: return "Keep running"
        case .ask: return "Ask"
        }
    }
}

/// "Swipe out to macOS" (org.omacvm.gestures SwipeOut, a bool, off by
/// default): OmacVM Gestures reads it from its own settings domain. Read as
/// CFPreferencesGetAppBooleanValue reads it: a bool, a number other than 0,
/// or the words true / yes.
public enum SwipeOut {
    public static let key = "SwipeOut"
    public static let defaultValue = false

    public static func isOn(stored: Any?) -> Bool {
        if let n = stored as? NSNumber { return n.doubleValue != 0 }
        if let s = stored as? String { return ["true", "yes"].contains(s.lowercased()) || (Int(s).map { $0 != 0 } ?? false) }
        return defaultValue
    }
}
