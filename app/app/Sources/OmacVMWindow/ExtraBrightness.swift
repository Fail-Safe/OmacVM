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

/// The VM's own Extra brightness switch (its Display panel, `omacvm
/// extra-brightness` in the VM; ADR 0031): GET or POST
/// /omacvm/app/extra-brightness on the VM's control port. The app answers it
/// itself and never passes it to the Bridge: the app opened that port for
/// this VM, so the VM is known, and the switch is the app's own setting. The
/// guest is untrusted: one exact path, a body of one real JSON boolean, only
/// while this VM's window is the app in front (a VM in the background must
/// not switch it for the one the user looks at), never with GPU safe mode or
/// without a display that has the headroom, at most 4 writes a second.
public enum ExtraBrightnessGuest {
    public static let path = "/omacvm/app/extra-brightness"

    /// Every /omacvm/app/ request is the app's own: one it does not know is
    /// answered 404 here, never relayed.
    public static func isApp(_ path: String) -> Bool { path.hasPrefix("/omacvm/app/") }

    /// What the app knows when the request comes (main thread).
    public struct Context: Equatable {
        /// A Mac display with the headroom (the app row's rule, Mac.hasExtraBrightnessDisplay).
        public var display: Bool
        /// This run of the VM has none: GPU safe mode or QEMU's CAOpenGLLayer present at its start.
        public var safeMode: Bool
        /// This VM's window (its QEMU) is the app in front.
        public var front: Bool
        /// The switch now.
        public var on: Bool
        public init(display: Bool, safeMode: Bool, front: Bool, on: Bool) {
            self.display = display; self.safeMode = safeMode; self.front = front; self.on = on
        }
    }

    public enum Decision: Equatable {
        case answer               // 200 with the state
        case set(Bool)            // the switch to this, then 200 with the new state
        case refuse(Int, String)  // status, code
    }

    /// GET: the state. POST {"on": true|false}: the switch. `writeAllowed`
    /// is asked last, for a write that would happen (the rate limit).
    public static func decide(method: String, path: String, body: Data?, _ c: Context,
                              writeAllowed: () -> Bool) -> Decision {
        guard path == Self.path else { return .refuse(404, "not-found") }
        switch method {
        case "GET":
            return body == nil ? .answer : .refuse(400, "bad-request")
        case "POST":
            guard let on = switchValue(body) else { return .refuse(400, "bad-request") }
            if !c.display { return .refuse(409, "no-display") }
            if c.safeMode { return .refuse(409, "safe-mode") }
            if !c.front { return .refuse(409, "not-front") }
            return writeAllowed() ? .set(on) : .refuse(429, "busy")
        default:
            return .refuse(405, "method")
        }
    }

    /// {"on": true|false} and nothing else; `on` a real JSON boolean (0 and
    /// 1 are numbers, not a switch).
    public static func switchValue(_ body: Data?) -> Bool? {
        guard let body, let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              o.count == 1, let v = o["on"] as? NSNumber, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return v.boolValue
    }

    /// The answer's body: {"display", "safe_mode", "on", "available"}.
    public static func state(_ c: Context) -> [String: Any] {
        ["display": c.display, "safe_mode": c.safeMode, "on": c.on, "available": c.display && !c.safeMode]
    }

    public static func error(_ code: String) -> String {
        switch code {
        case "not-found": return "not found"
        case "bad-request": return "send {\"on\": true} or {\"on\": false}"
        case "no-display": return "no Mac display with extra brightness (an XDR display)"
        case "safe-mode": return "off while GPU safe mode is on (this start of the VM)"
        case "not-front": return "only while this VM's window is in front"
        case "busy": return "too many changes: at most 4 a second"
        default: return "GET or POST"
        }
    }
}

/// At most `limit` writes in any second (ExtraBrightnessGuest). Main thread only.
public struct WriteRate {
    public static let limit = 4
    private var times: [Double] = []
    public init() {}
    /// A write at `now` (seconds, monotonic): true when it may happen (and is counted).
    public mutating func take(at now: Double) -> Bool {
        times.removeAll { now - $0 >= 1 || now < $0 }
        guard times.count < Self.limit else { return false }
        times.append(now)
        return true
    }
}
