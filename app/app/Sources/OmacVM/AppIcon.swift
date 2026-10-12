import AppKit
import OmacVMWindow
import SwiftUI

/// The app icon's look (IconTheme, org.omacvm.app appIconTheme): drawn for
/// the header, the Dock (NSApp.applicationIconImage, at each launch and when
/// it changes) and QEMU's window (OMACVM_ICON: a PNG in the run folder). The
/// icon in the app bundle stays as it is.
@MainActor
enum AppIcon {
    static let changed = Notification.Name("OmacVM.AppIcon.changed")

    static var theme: IconTheme { IconTheme.choice(stored: UserDefaults.standard.object(forKey: IconTheme.key)) }

    static func set(_ t: IconTheme) {
        if t.isDefault {
            UserDefaults.standard.removeObject(forKey: IconTheme.key)
        } else {
            UserDefaults.standard.set(t.id, forKey: IconTheme.key)
        }
        apply()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The Dock's icon for this launch.
    static func apply() {
        let t = theme
        NSApp.applicationIconImage = t.isDefault ? nil : image(t, size: 1024)
    }

    /// The icon in a look, `size` points square.
    static func image(_ t: IconTheme, size: CGFloat) -> NSImage {
        if t.isDefault, let icon = bundleIcon { return icon }
        let colors = t.colors ?? defaultColors
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(colors, dark: t.dark, in: cg, scale: rect.width / 1024)
            return true
        }
    }

    /// The bundle's own icon (nil in `swift run`).
    private static let bundleIcon: NSImage? = Paths.icon.flatMap { NSImage(contentsOf: $0) }

    /// OmacVM's own colours (src/icon/omacvm.svg), when the bundle has no icon.
    private static let defaultColors = IconTheme.Colors(background: 0x26233a, pad: 0x1b1928, loops: 0xc4a7e7, mark: 0xe0def4)

    /// The PNG QEMU shows in the Dock while the VM runs; nil: the bundle's icon.
    static func fileForQEMU() -> URL? {
        let t = theme
        guard !t.isDefault else { return nil }
        let url = Paths.runDir.appendingPathComponent("icon-\(Bundle.main.bundleIdentifier ?? "omacvm")-\(t.id).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.translateBy(x: 0, y: 1024)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        draw(t.colors ?? defaultColors, dark: t.dark, in: ctx.cgContext, scale: 1)
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// src/icon/omacvm.svg with other colours, in the SVG's coordinates (top left).
    private static func draw(_ c: IconTheme.Colors, dark: Bool, in cg: CGContext, scale s: CGFloat) {
        func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor { NSColor(rgb: v, alpha: a).cgColor }
        func shade(_ v: UInt32, _ f: CGFloat) -> CGColor {
            let n = NSColor(rgb: v)
            return (n.blended(withFraction: f, of: .black) ?? n).cgColor
        }
        let b = IconTheme.body
        cg.saveGState()
        cg.scaleBy(x: s, y: s)
        // The shadow under the square.
        let shadow = CGPath(roundedRect: CGRect(x: b.x, y: b.y + 12, width: b.size, height: b.size),
                            cornerWidth: b.radius, cornerHeight: b.radius, transform: nil)
        cg.addPath(shadow)
        cg.setFillColor(CGColor(gray: 0, alpha: dark ? 0.28 : 0.16))
        cg.fillPath()
        let body = CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.size, height: b.size),
                          cornerWidth: b.radius, cornerHeight: b.radius, transform: nil)
        cg.saveGState()
        cg.addPath(body)
        cg.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [rgb(c.background), shade(c.background, dark ? 0.45 : 0.06)] as CFArray,
                                  locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: b.y), end: CGPoint(x: 0, y: b.y + b.size), options: [])
        cg.setStrokeColor(rgb(c.loops))
        cg.setLineWidth(IconTheme.loops.width)
        for (x, y) in IconTheme.loops.centres {
            let r = IconTheme.loops.radius
            cg.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        let p = IconTheme.pad
        cg.setFillColor(rgb(c.pad))
        cg.fill(CGRect(x: p.x, y: p.y, width: p.size, height: p.size))
        cg.setFillColor(rgb(c.mark))
        for r in IconTheme.mark { cg.fill(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) }
        cg.restoreGState()
        // The edge: light on dark, dark on light.
        let edge = CGPath(roundedRect: CGRect(x: b.x + 1.5, y: b.y + 1.5, width: b.size - 3, height: b.size - 3),
                          cornerWidth: b.radius - 1.5, cornerHeight: b.radius - 1.5, transform: nil)
        cg.addPath(edge)
        cg.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.08) : CGColor(gray: 0, alpha: 0.10))
        cg.setLineWidth(3)
        cg.strokePath()
        cg.restoreGState()
    }
}

/// The header's icon: click it for the looks (two rows: dark, then light).
struct AppIconButton: View {
    var size: CGFloat = 32
    @State private var theme = AppIcon.theme
    @State private var open = false
    /// The window pictures: the popover's content drawn on its own.
    var preview: Bool = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(nsImage: AppIcon.image(theme, size: size))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help("\(Product.name)")
        .accessibilityLabel("\(Product.name) icon")
        .accessibilityHint("Shows other looks for the icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AppIconPicker(selected: theme) { t in
                AppIcon.set(t)
                theme = t
                open = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppIcon.changed)) { _ in theme = AppIcon.theme }
        .layoutProbe("app-icon")
    }
}

/// The eight looks: OmacVM's own and three dark Omarchy themes on top, four light ones below.
struct AppIconPicker: View {
    let selected: IconTheme
    let pick: (IconTheme) -> Void

    var body: some View {
        let rows = [IconTheme.all.filter(\.dark), IconTheme.all.filter { !$0.dark }]
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r]) { t in
                        Button { pick(t) } label: {
                            Image(nsImage: AppIcon.image(t, size: 36))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 36, height: 36)
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(t == selected ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(t.name)
                        .accessibilityLabel(t.name)
                        .accessibilityAddTraits(t == selected ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(10)
    }
}
