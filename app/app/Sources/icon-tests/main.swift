// The icon's looks as the Dock shows them: IconArt's drawing of each look
// (the launcher's and QEMU's tiles). `swift run icon-tests [DIR]`: DIR gets a
// picture of each look (dock-<id>.png).
import AppKit
import OmacVMIcon

var failures = 0
func expect(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

/// The pixel at x, y (from the top left, in the 1024 canvas) of a 256-pixel icon.
func pixel(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
    let px = Int(x / 4), py = Int(y / 4)
    guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
    return (Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5), Int(c.alphaComponent * 255 + 0.5))
}
func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ v: UInt32, _ tol: Int = 12) -> Bool {
    abs(p.r - Int((v >> 16) & 0xff)) <= tol && abs(p.g - Int((v >> 8) & 0xff)) <= tol && abs(p.b - Int(v & 0xff)) <= tol && p.a > 240
}
func hex(_ p: (r: Int, g: Int, b: Int, a: Int)) -> String { String(format: "%02x%02x%02x/%d", p.r, p.g, p.b, p.a) }

// Each look's picture: its own colours where the SVG has them.
for t in IconTheme.all {
    guard let rep = IconArt.bitmap(t, pixels: 256) else { expect(false, "\(t.id): no picture"); continue }
    let c = t.colors ?? IconArt.defaultColors
    let bg = pixel(rep, 512, 130), loop = pixel(rep, 330, 330 - 92), pad = pixel(rep, 340, 340), mark = pixel(rep, 380, 376)
    let corner = pixel(rep, 8, 8)
    expect(near(bg, c.background, 14) && near(loop, c.loops) && near(pad, c.pad) && near(mark, c.mark) && corner.a == 0,
           "\(t.id): background \(hex(bg)), loops \(hex(loop)), pad \(hex(pad)), mark \(hex(mark)), outside the square clear")
    if let out, let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out.appendingPathComponent("dock-\(t.id).png"))
    }
}
// Light and dark looks differ where the eye looks first.
if let a = IconArt.bitmap(IconTheme.choice(stored: "tokyo-night"), pixels: 256),
   let b = IconArt.bitmap(IconTheme.choice(stored: "flexoki-light"), pixels: 256) {
    expect(pixel(a, 512, 130).r < 80 && pixel(b, 512, 130).r > 200, "Tokyo Night is dark, Flexoki Light is light")
}

print(failures == 0 ? "icon: all checks passed" : "icon: \(failures) failed")
exit(failures == 0 ? 0 : 1)
