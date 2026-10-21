import Foundation

/// Extra brightness (ADR 0050, experimental, off by default): QEMU draws the
/// VM's main window up to twice as bright as the Mac's white on a display
/// with EDR headroom above 2x (an XDR panel), live while the VM runs
/// (omacvm-cocoa-extra-brightness.patch). The app only shows the row and
/// keeps the switch; QEMU reads the key itself.
public enum ExtraBrightness {
    /// The app's defaults key (org.omacvm.app; the test identity's domain).
    public static let key = "extraBrightness"
    /// A display shows it only above this EDR potential: SDR panels report
    /// 2.0 (MacBook Air), XDR panels 16. QEMU uses the same number
    /// (OMACVM_BRIGHT_MIN_POTENTIAL in ui/omacvm-bright.h).
    public static let minPotential = 2.05

    /// The row shows when one of the Mac's displays has the headroom.
    public static func available(potentials: [Double]) -> Bool {
        potentials.contains { $0.isFinite && $0 > minPotential }
    }

    /// The answer at a start of the VM, for QEMU's environment and qemu.log.
    /// QEMU follows the switch live and says itself what it does; this is
    /// what the app knows when it starts QEMU.
    public static func start(on: Bool, display: Bool, gpuSafeMode: Bool, layerPresent: Bool) -> (on: Bool, why: String) {
        if !on { return (false, "switch off") }
        if gpuSafeMode { return (false, "GPU safe mode") }
        if layerPresent { return (false, "OMACVM_GL_PRESENT=layer: frames in a CAOpenGLLayer") }
        if !display { return (false, "no display with extra brightness") }
        return (true, "up to 2x on a display with the headroom")
    }
}
