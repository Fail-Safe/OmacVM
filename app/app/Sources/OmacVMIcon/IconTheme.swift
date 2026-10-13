import Foundation

/// The app icon's looks (the header's icon, click: the easter egg). OmacVM's
/// own icon and Omarchy's stock themes: four dark, four light. The choice is
/// org.omacvm.app appIconTheme. IconArt draws it: the launcher's Dock tile
/// (NSApp.applicationIconImage), QEMU's (a PNG), and the Dock tile plug-in's
/// while the app is not running (OmacVMDockTile). The icon file in the app
/// bundle is never changed (its signature covers it).
public struct IconTheme: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let dark: Bool
    /// nil: OmacVM's own icon (the bundle's).
    public let colors: Colors?

    public struct Colors: Equatable, Sendable {
        /// The icon's square, the inner square behind the mark, the four loops, the mark.
        public let background: UInt32, pad: UInt32, loops: UInt32, mark: UInt32

        public init(background: UInt32, pad: UInt32, loops: UInt32, mark: UInt32) {
            self.background = background; self.pad = pad; self.loops = loops; self.mark = mark
        }
    }

    public static let key = "appIconTheme"
    public static let defaultID = "default"
    /// Posted (distributed, object: the app's bundle id) when the look
    /// changes: the Dock tile plug-in draws it again.
    public static let changedNotification = "org.omacvm.app.iconTheme.changed"

    /// Dark first, then light: the popover's two rows. The ids are Omarchy's
    /// theme folders (omarchy-theme-set); the colours come from each theme's
    /// palette.
    public static let all: [IconTheme] = [
        IconTheme(id: defaultID, name: "OmacVM", dark: true, colors: nil),
        IconTheme(id: "tokyo-night", name: "Tokyo Night", dark: true,
                  colors: Colors(background: 0x1f2335, pad: 0x16161e, loops: 0x7aa2f7, mark: 0xc0caf5)),
        IconTheme(id: "catppuccin", name: "Catppuccin", dark: true,
                  colors: Colors(background: 0x313244, pad: 0x1e1e2e, loops: 0xcba6f7, mark: 0xcdd6f4)),
        IconTheme(id: "gruvbox", name: "Gruvbox", dark: true,
                  colors: Colors(background: 0x3c3836, pad: 0x282828, loops: 0xfabd2f, mark: 0xebdbb2)),
        IconTheme(id: "flexoki-light", name: "Flexoki Light", dark: false,
                  colors: Colors(background: 0xf2f0e5, pad: 0xe6e4d9, loops: 0x205ea6, mark: 0x100f0f)),
        IconTheme(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false,
                  colors: Colors(background: 0xe6e9ef, pad: 0xdce0e8, loops: 0x8839ef, mark: 0x4c4f69)),
        IconTheme(id: "rose-pine", name: "Rosé Pine", dark: false,
                  colors: Colors(background: 0xfaf4ed, pad: 0xf2e9e1, loops: 0x907aa9, mark: 0x575279)),
        IconTheme(id: "lupine", name: "Lupine", dark: false,
                  colors: Colors(background: 0xf2f2f4, pad: 0xe4e4e9, loops: 0x3264eb, mark: 0x212121)),
    ]

    /// The stored choice; anything unknown (or nothing) is OmacVM's own icon.
    public static func choice(stored: Any?) -> IconTheme {
        let id = stored as? String
        return all.first { $0.id == id } ?? all[0]
    }

    public var isDefault: Bool { colors == nil }

    // MARK: The drawing (src/icon/omacvm.svg, a 1024 x 1024 canvas)

    /// The rounded square: x, y, size, corner radius.
    public static let body = (x: 100.0, y: 100.0, size: 824.0, radius: 185.0)
    /// The Command key's four loops: centres, radius, line width.
    public static let loops = (centres: [(330.0, 330.0), (694.0, 330.0), (330.0, 694.0), (694.0, 694.0)], radius: 92.0, width: 44.0)
    /// The square behind Omarchy's mark.
    public static let pad = (x: 330.0, y: 330.0, size: 364.0)
    /// Omarchy's mark (from Omarchy's icon.txt, MIT, basecamp/omarchy) as
    /// rectangles: x, y, width, height, from the top left.
    public static let mark: [[Double]] = [
        [362.00, 367.56, 300.60, 22.82], [362.00, 389.78, 22.82, 22.82], [500.89, 389.78, 22.82, 22.82],
        [639.78, 389.78, 22.82, 22.82], [362.00, 412.00, 22.82, 22.82], [406.44, 412.00, 117.27, 22.82],
        [573.11, 412.00, 45.04, 22.82], [639.78, 412.00, 22.82, 22.82], [362.00, 434.22, 22.82, 22.82],
        [406.44, 434.22, 22.82, 22.82], [595.33, 434.22, 22.82, 22.82], [639.78, 434.22, 22.82, 22.82],
        [362.00, 456.44, 22.82, 22.82], [406.44, 456.44, 22.82, 22.82], [595.33, 456.44, 22.82, 22.82],
        [639.78, 456.44, 22.82, 22.82], [362.00, 478.67, 22.82, 22.82], [406.44, 478.67, 22.82, 22.82],
        [595.33, 478.67, 22.82, 22.82], [639.78, 478.67, 22.82, 22.82], [362.00, 500.89, 67.27, 22.82],
        [595.33, 500.89, 22.82, 22.82], [639.78, 500.89, 22.82, 22.82], [362.00, 523.11, 22.82, 22.82],
        [406.44, 523.11, 22.82, 22.82], [595.33, 523.11, 22.82, 22.82], [639.78, 523.11, 22.82, 22.82],
        [362.00, 545.33, 22.82, 22.82], [406.44, 545.33, 22.82, 22.82], [595.33, 545.33, 22.82, 22.82],
        [639.78, 545.33, 22.82, 22.82], [362.00, 567.56, 22.82, 22.82], [406.44, 567.56, 22.82, 22.82],
        [595.33, 567.56, 22.82, 22.82], [639.78, 567.56, 22.82, 22.82], [362.00, 589.78, 22.82, 22.82],
        [406.44, 589.78, 211.71, 22.82], [639.78, 589.78, 22.82, 22.82], [362.00, 612.00, 22.82, 22.82],
        [500.89, 612.00, 22.82, 22.82], [639.78, 612.00, 22.82, 22.82], [362.00, 634.22, 161.71, 22.82],
        [550.89, 634.22, 111.71, 22.82],
    ]
}
