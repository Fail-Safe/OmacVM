import AppKit

/// The icon in a look: src/icon/omacvm.svg with other colours. One drawing
/// for every place it shows: the window's header and the launcher's and
/// QEMU's Dock tiles.
public enum IconArt {
    /// OmacVM's own colours (src/icon/omacvm.svg), when there is no bundle icon.
    public static let defaultColors = IconTheme.Colors(background: 0x26233a, pad: 0x1b1928, loops: 0xc4a7e7, mark: 0xe0def4)

    /// The icon of a look, `size` points square, drawn at any scale.
    public static func image(_ t: IconTheme, size: CGFloat) -> NSImage {
        let colors = t.colors ?? defaultColors
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(colors, dark: t.dark, in: cg, scale: rect.width / 1024)
            return true
        }
    }

    /// The icon as pixels, `pixels` square (QEMU's icon file, the tests).
    public static func bitmap(_ t: IconTheme, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        let side = CGFloat(pixels)
        ctx.cgContext.translateBy(x: 0, y: side)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        draw(t.colors ?? defaultColors, dark: t.dark, in: ctx.cgContext, scale: side / 1024)
        ctx.flushGraphics()
        return rep
    }

    /// src/icon/omacvm.svg with other colours, in the SVG's coordinates (top left).
    public static func draw(_ c: IconTheme.Colors, dark: Bool, in cg: CGContext, scale s: CGFloat) {
        func color(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        func rgb(_ v: UInt32) -> CGColor { color(v).cgColor }
        func shade(_ v: UInt32, _ f: CGFloat) -> CGColor {
            let n = color(v)
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
