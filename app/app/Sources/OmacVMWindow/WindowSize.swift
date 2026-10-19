import Foundation

/// The app's window (docs/design/settings-3.1): 800 pt wide, a sidebar of
/// 200 pt and the content beside it. Only the height can change (500 pt at
/// least); it opens as tall as the screen shows below the menu bar and above
/// the Dock, less a margin, but no taller than 800 pt: on a large display a
/// window as tall as the screen looked stretched. The settings scroll inside it.
public enum WindowSize {
    public static let width: Double = 800
    public static let sidebar: Double = 200
    public static let minHeight: Double = 500
    /// Kept free above and below the window on its screen.
    public static let margin: Double = 16
    /// The tallest it opens; the user can still drag it taller.
    public static let maxDefaultHeight: Double = 800

    /// A 13-inch MacBook Air at its default resolution, with the menu bar and
    /// the Dock, shows about this much: the window pictures are drawn at its
    /// default height and must fit it (`OmacVM --render-vm-window`).
    public static let smallScreenVisible: Double = 792

    /// The height the window opens with on a screen whose visible frame is
    /// `visible` tall.
    public static func defaultHeight(visible: Double) -> Double {
        max(minHeight, min(maxDefaultHeight, (visible - 2 * margin).rounded(.down)))
    }

    /// The window's frame (x, width) after something made it wider or
    /// narrower than `width`: as wide as before, around the same middle. The
    /// height stays as it was given. macOS's Fill (a double-click on the title
    /// bar) and window tiling do not keep to the window's maximum width.
    public static func fixedWidth(x: Double, width w: Double) -> (x: Double, width: Double) {
        ((x + w / 2 - width / 2).rounded(), width)
    }
}

/// Which section the sidebar marks while the settings scroll. A probe line
/// sits `inset` below the top of the visible part: the section whose heading
/// has passed it is marked, as usual. Only over the last stretch of the scroll
/// (one visible height minus the inset, or the whole scroll when it is
/// shorter) does the line move down, to the end of the content at the very
/// bottom. So the last sections, which can never scroll up to the top, are
/// marked in turn too, and the last one at the bottom. The probe only moves
/// forward and runs over the whole content: every section is marked once on
/// the way down.
public enum ScrollSpy {
    public static let inset: Double = 90

    /// - tops: each section's top in the content, from the content's top (in order).
    /// - offset: how far the content is scrolled (0 at the top).
    /// - maxOffset: how far it can scroll (0 or less: it fits, nothing scrolls).
    /// - viewport: the height of the visible part.
    public static func current(tops: [Double], offset: Double, maxOffset: Double, viewport: Double,
                               inset: Double = inset) -> Int {
        guard !tops.isEmpty, maxOffset > 0 else { return 0 }
        let probe = probe(offset: offset, maxOffset: maxOffset, viewport: viewport, inset: inset)
        var i = 0
        for (k, top) in tops.enumerated() where top <= probe { i = k }
        return i
    }

    /// The probe line in content coordinates: `inset` below the visible top
    /// until the last stretch of the scroll, then moving down to the content's
    /// end (offset + viewport) at the very bottom.
    public static func probe(offset: Double, maxOffset: Double, viewport: Double, inset: Double = inset) -> Double {
        let start = min(inset, viewport)
        let stretch = min(maxOffset, viewport - start)
        let t = stretch > 0 ? min(max((offset - (maxOffset - stretch)) / stretch, 0), 1) : (offset >= maxOffset ? 1 : 0)
        return offset + start + t * (viewport - start)
    }
}

/// A click in the sidebar marks its section at once and keeps it marked
/// while the click's scroll runs and afterwards (the last sections cannot
/// bring their heading to the top), until the person scrolls by hand.
public struct ScrollSpyPin: Equatable, Sendable {
    public private(set) var pinned: Int?
    /// The click's own scroll is still running: its moves are not the person's.
    public private(set) var scrolling = false

    public init() {}

    public mutating func click(_ section: Int) {
        pinned = section
        scrolling = true
    }

    /// The click's scroll has ended (or never started: nothing to scroll).
    public mutating func clickScrollEnded() { scrolling = false }

    /// A scroll by the person (wheel, trackpad, scroll bar).
    public mutating func scrolledByHand() {
        pinned = nil
        scrolling = false
    }

    /// The content moved: after the click's scroll that is the person's.
    public mutating func moved() {
        if !scrolling { pinned = nil }
    }

    public func marked(_ computed: Int) -> Int { pinned ?? computed }
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

/// The Delete sheet: Delete only once the VM's name is typed exactly.
public enum DeleteConfirm {
    public static func matches(typed: String, name: String) -> Bool {
        !name.isEmpty && typed == name
    }
}
