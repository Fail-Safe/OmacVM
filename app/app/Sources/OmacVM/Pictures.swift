import SwiftUI

/// The pictures of the VM window (docs/design/settings-3.1/final.html):
/// how a VM starts and what the escape combo takes back to macOS. Drawn in the design's coordinates and scaled; Omarchy is drawn
/// in Rosé Pine Dawn's colours, macOS's desktop in its own, in light and dark.
private struct Sketch {
    var ctx: GraphicsContext
    let k: CGFloat

    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0, fill: Color? = nil,
              stroke: Color? = nil, line: CGFloat = 1, dash: [CGFloat] = []) {
        let path = Path(roundedRect: r(x, y, w, h), cornerRadius: radius * k)
        if let fill { ctx.fill(path, with: .color(fill)) }
        if let stroke {
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: line * k, dash: dash.map { $0 * k }))
        }
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ fill: Color) {
        ctx.fill(Path(ellipseIn: r(cx - radius, cy - radius, 2 * radius, 2 * radius)), with: .color(fill))
    }

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, _ color: Color) {
        ctx.draw(Text(s).font(.system(size: size * k)).foregroundStyle(color), at: CGPoint(x: x * k, y: y * k), anchor: .bottom)
    }

    func clipped(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, _ draw: (Sketch) -> Void) {
        var c = ctx
        c.clip(to: Path(roundedRect: r(x, y, w, h), cornerRadius: radius * k))
        draw(Sketch(ctx: c, k: k))
    }

    func line(_ points: [(CGFloat, CGFloat)], _ color: Color, width: CGFloat) {
        var p = Path()
        for (i, pt) in points.enumerated() {
            let q = CGPoint(x: pt.0 * k, y: pt.1 * k)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width * k, lineCap: .round, lineJoin: .round))
    }

    func curve(_ from: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
               _ color: Color, width: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: from.0 * k, y: from.1 * k))
        p.addCurve(to: CGPoint(x: to.0 * k, y: to.1 * k), control1: CGPoint(x: c1.0 * k, y: c1.1 * k),
                   control2: CGPoint(x: c2.0 * k, y: c2.1 * k))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width * k, lineCap: .round))
    }
}

/// Rosé Pine Dawn (Omarchy) and macOS's desktop.
private enum Ink {
    static let desk = Color(rgb: 0xD8E3F0), menu = Color(rgb: 0xF7F7F8), menuItem = Color(rgb: 0xB9B9BF)
    static let base = Color(rgb: 0xE9E0D6), bar = Color(rgb: 0xFAF4ED), titleBar = Color(rgb: 0xF2ECE4)
    static let surface = Color(rgb: 0xFFFAF3), border = Color(rgb: 0xDCD3C9), rose = Color(rgb: 0xD7827E)
    static let pine = Color(rgb: 0x286983), muted = Color(rgb: 0xB5AFB8), gold = Color(rgb: 0xEA9D34)
    static let iris = Color(rgb: 0x907AA9), text = Color(rgb: 0x575279), dot = Color(rgb: 0xD5CCC2)
    static let subtle = Color(rgb: 0x9893A5), notch = Color(rgb: 0x0F0F10), stand = Color(rgb: 0x8E8E93)
    static let accent = Color(rgb: 0x0A84FF)
}

/// How a VM starts: in a window on the desktop, or full screen (with the
/// notch drawn on a Mac that has one).
struct StartInPicture: View {
    enum Kind { case window, fullScreen, fullScreenNotch }
    let kind: Kind
    var notch = true

    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 160)
            s.clipped(0, 0, 160, 98, radius: 8) { s in
                switch kind {
                case .window: window(s)
                case .fullScreen, .fullScreenNotch: full(s)
                }
            }
            s.rect(0.5, 0.5, 159, 97, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 150, height: 91.9)
        .accessibilityHidden(true)
    }

    private func window(_ s: Sketch) {
        s.rect(0, 0, 160, 98, fill: Ink.desk)
        s.rect(0, 0, 160, 10, fill: Ink.menu)
        s.circle(8, 5, 1.4, Ink.stand)
        s.rect(14, 3.8, 16, 2.4, radius: 1.2, fill: Ink.menuItem)
        s.rect(138, 3.8, 14, 2.4, radius: 1.2, fill: Ink.menuItem)
        s.rect(60, 89, 40, 5, radius: 2.5, fill: .white.opacity(0.85))
        s.clipped(40, 22, 80, 58, radius: 4) { s in
            s.rect(40, 22, 80, 58, fill: Ink.base)
            s.rect(40, 22, 80, 10, fill: Ink.titleBar)
            s.circle(46.5, 27, 1.6, Color(rgb: 0xFF5F57))
            s.circle(51.5, 27, 1.6, Color(rgb: 0xFEBC2E))
            s.circle(56.5, 27, 1.6, Color(rgb: 0x28C840))
            s.rect(40, 32, 80, 5, fill: Ink.bar)
            s.rect(43, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.rose)
            s.rect(47, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
            s.rect(51, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
            s.rect(76, 33.6, 9, 1.8, radius: 0.9, fill: Ink.text)
            s.rect(44, 41, 44, 35, radius: 2, fill: Ink.surface, stroke: Ink.rose)
            s.rect(92, 41, 24, 16, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(92, 60, 24, 16, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(48, 46, 18, 2.2, radius: 1.1, fill: Ink.pine)
            s.rect(48, 51, 28, 2.2, radius: 1.1, fill: Ink.muted)
            s.rect(48, 56, 22, 2.2, radius: 1.1, fill: Ink.muted)
            s.rect(48, 61, 14, 2.2, radius: 1.1, fill: Ink.gold)
        }
        s.rect(40, 22, 80, 58, radius: 4, stroke: .black.opacity(0.3), line: 0.7)
    }

    private func full(_ s: Sketch) {
        s.rect(0, 0, 160, 98, fill: Ink.base)
        s.rect(0, 0, 160, 9, fill: Ink.bar)
        s.rect(4, 2.5, 4, 4, radius: 1, fill: Ink.rose)
        for x in [10.0, 16, 22, 28] { s.rect(x, 2.5, 4, 4, radius: 1, fill: Ink.dot) }
        s.rect(74, 3.2, 13, 2.6, radius: 1.3, fill: Ink.text)
        for x in [147.0, 152, 157] { s.circle(x, 4.5, 1.2, Ink.subtle) }
        if notch { s.rect(66, 0, 28, 7.5, radius: 2.5, fill: Ink.notch) }
        // Omanotch's strip ends in a line; the VM's own bar does not.
        if kind == .fullScreen && notch { s.rect(0, 9, 160, 0.7, fill: .black.opacity(0.18)) }
        s.rect(6, 15, 90, 75, radius: 3, fill: Ink.surface, stroke: Ink.rose, line: 1.2)
        s.rect(100, 15, 54, 35, radius: 3, fill: Ink.surface, stroke: Ink.border)
        s.rect(100, 54, 54, 36, radius: 3, fill: Ink.surface, stroke: Ink.border)
        s.rect(12, 22, 30, 2.6, radius: 1.3, fill: Ink.pine)
        s.rect(12, 28, 52, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 34, 40, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 40, 58, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 46, 24, 2.6, radius: 1.3, fill: Ink.gold)
        s.rect(106, 22, 24, 2.6, radius: 1.3, fill: Ink.pine)
        s.rect(106, 28, 34, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(106, 61, 30, 2.6, radius: 1.3, fill: Ink.iris)
        s.rect(106, 67, 22, 2.6, radius: 1.3, fill: Ink.muted)
    }
}

/// The escape combo: the monitor under the pointer goes to macOS, or all of them.
struct EscapePicture: View {
    let all: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 170)
            s.rect(0, 0, 170, 100, radius: 8, fill: Look.panel)
            s.rect(61, 6, 48, 14, radius: 3, fill: Look.key, stroke: Ink.accent, line: 1.2)
            s.text("⌃⌥ esc", 85, 16.5, size: 7, Color.accentColor)
            monitor(s, x: 10, macOS: true, pointer: true)
            monitor(s, x: 90, macOS: all, pointer: false)
            s.rect(0.5, 0.5, 169, 99, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 170, height: 100)
        .accessibilityHidden(true)
    }

    private func monitor(_ s: Sketch, x: CGFloat, macOS: Bool, pointer: Bool) {
        s.clipped(x, 30, 70, 44, radius: 3) { s in
            if macOS {
                s.rect(x, 30, 70, 44, fill: Ink.desk)
                s.rect(x, 30, 70, 5, fill: Ink.menu)
                s.rect(x + 23, 69, 24, 3, radius: 1.5, fill: .white.opacity(0.85))
            } else {
                s.rect(x, 30, 70, 44, fill: Ink.base)
                s.rect(x, 30, 70, 5, fill: Ink.bar)
                s.rect(x + 3, 31.2, 2.6, 2.6, radius: 0.8, fill: Ink.rose)
                s.rect(x + 7, 31.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
                s.rect(x + 32, 31.6, 8, 1.8, radius: 0.9, fill: Ink.text)
                s.rect(x + 4, 39, 34, 31, radius: 2, fill: Ink.surface, stroke: Ink.rose)
                s.rect(x + 41, 39, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
                s.rect(x + 41, 56, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
                s.rect(x + 8, 44, 16, 2, radius: 1, fill: Ink.pine)
                s.rect(x + 8, 49, 22, 2, radius: 1, fill: Ink.muted)
                s.rect(x + 8, 54, 14, 2, radius: 1, fill: Ink.gold)
            }
        }
        s.rect(x, 30, 70, 44, radius: 3, stroke: Ink.stand, line: 1.4)
        s.line([(x + 35, 74), (x + 35, 79)], Ink.stand, width: 1.6)
        s.line([(x + 24, 79), (x + 46, 79)], Ink.stand, width: 1.6)
        if pointer {
            var p = Path()
            let k = s.k, px = x + 32, py: CGFloat = 46
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 9.2), (2.1, 7.2), (3.6, 10.4), (5.1, 9.7), (3.6, 6.5), (6.4, 6.3)]
            for (i, q) in pts.enumerated() {
                let pt = CGPoint(x: (px + q.0) * k, y: (py + q.1) * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            s.ctx.fill(p, with: .color(Color(rgb: 0x1D1D1F)))
            s.ctx.stroke(p, with: .color(.white), lineWidth: 0.6 * k)
        }
    }
}
