import Foundation

/// Is this Mac set up for an OmacVM.app VM? `src/mac/install.sh --status
/// VM_DIR` (mac_setup_state in src/lib/mac-setup.sh, the same answer omacvm
/// check prints as "Mac setup") says it in "key<TAB>value" lines; this reads
/// them and words what the app tells the person before a start and in the
/// window. A VM folder copied from another Mac runs without the Mac helpers
/// its features need (only Update VM, a build or omacvm apply install them),
/// and nothing said so (2026-10-20). Nothing here installs anything: the
/// person chooses Update VM, which installs them, and the helpers ask macOS
/// for their permissions themselves.
public struct MacSetup: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        case ok, none, setup, permission
        case loginItems = "login-items"
    }
    /// What fixes it: Update VM, OmacVM itself first (the VM has a newer
    /// OmacVM: Update VM would stop before the Mac side), a System Settings
    /// pane, the Login Items pane.
    public enum Fix: String, Sendable {
        case none = ""
        case updateVM = "update-vm"
        case updateApp = "update-app"
        case settings
        case loginItems = "login-items"
    }
    public struct Helper: Equatable, Sendable {
        public let name: String, state: String, detail: String
        public init(name: String, state: String, detail: String) {
            self.name = name; self.state = state; self.detail = detail
        }
    }

    public var verdict: Verdict
    public var fix: Fix = .none
    /// For setup: other-mac, not-installed, not-running, too-old.
    public var why = ""
    /// The helpers it is about.
    public var helpers: [String] = []
    /// Every helper the VM's features need on this Mac.
    public var needed: [String] = []
    /// For permission: "Accessibility", "Input Monitoring" or both.
    public var missing = ""
    public var version = ""
    public var vmVersion = ""
    /// omacvm check's words.
    public var text = ""
    public var lines: [Helper] = []

    public init(verdict: Verdict) { self.verdict = verdict }

    /// The script's output; nil without a verdict it knows.
    public static func parse(_ out: String) -> MacSetup? {
        var s: MacSetup?
        var f: [String: String] = [:]
        var lines: [Helper] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2 else { continue }
            if p[0] == "helper", p.count >= 4 {
                lines.append(Helper(name: p[1], state: p[2], detail: p[3]))
            } else {
                f[p[0]] = p[1]
            }
        }
        guard let v = f["verdict"].flatMap(Verdict.init(rawValue:)) else { return nil }
        s = MacSetup(verdict: v)
        s?.fix = Fix(rawValue: f["fix"] ?? "") ?? .none
        s?.why = f["why"] ?? ""
        s?.helpers = Self.names(f["helpers"])
        s?.needed = Self.names(f["needed"])
        s?.missing = f["missing"] ?? ""
        s?.version = f["version"] ?? ""
        s?.vmVersion = f["vm-version"] ?? ""
        s?.text = f["text"] ?? ""
        s?.lines = lines.sorted { rank($0.name) < rank($1.name) }
        return s
    }

    /// Gestures first: trackpad gestures are what people miss first.
    private static func rank(_ h: String) -> Int {
        ["OmacVM Gestures", "OmacVM Bridge", "Omanotch"].firstIndex(of: h) ?? 9
    }

    private static func names(_ s: String?) -> [String] {
        (s ?? "").split(separator: "|").map(String.init).sorted { rank($0) < rank($1) }
    }

    /// Something the person should hear about.
    public var needsAction: Bool { verdict == .setup || verdict == .permission || verdict == .loginItems }

    /// The window's Update VM button (beside Start) is the fix.
    public var wantsUpdateVM: Bool { verdict == .setup && fix == .updateVM }

    // MARK: Words

    /// What each helper does, in a few words.
    public static func serves(_ helper: String) -> String {
        switch helper {
        case "OmacVM Gestures": return "trackpad gestures, scroll momentum and ⌃⌥ Esc"
        case "OmacVM Bridge": return "the Mac's Wi-Fi, Bluetooth, sound and media keys in Omarchy's bar"
        case "Omanotch": return "the bar beside the notch"
        default: return helper
        }
    }

    /// The same, shorter (the window's notice).
    public static func servesShort(_ helper: String) -> String {
        switch helper {
        case "OmacVM Gestures": return "trackpad gestures"
        case "OmacVM Bridge": return "the Mac's Wi-Fi, sound and keys in the bar"
        case "Omanotch": return "the bar beside the notch"
        default: return helper
        }
    }

    /// The permissions macOS asks for when a helper is installed.
    public static func asks(_ helper: String) -> String? {
        switch helper {
        case "OmacVM Gestures": return "Accessibility and Input Monitoring"
        case "OmacVM Bridge": return "Accessibility, Input Monitoring, Location Services and Bluetooth"
        default: return nil
        }
    }

    /// "A", "A and B", "A, B and C".
    public static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
    }

    private var one: Bool { helpers.count == 1 }
    private var names: String { Self.list(helpers) }
    private var isnt: String { one ? "isn't" : "aren't" }
    private var them: String { one ? "it" : "them" }
    /// What does nothing without them (a comma before the last "and": the
    /// parts have an "and" of their own).
    private var features: String {
        let parts = helpers.map(Self.serves)
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + ", and " + last
    }

    private static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The alert's title before a start.
    public func title(vm: String) -> String {
        switch verdict {
        case .setup where fix == .updateApp: return "\(vm) needs a newer OmacVM"
        case .setup where why == "other-mac": return "\(vm) was set up on another Mac"
        case .setup where why == "too-old": return "\(names) on this Mac \(one ? "is" : "are") too old for this app"
        case .setup where why == "not-running": return "\(names) \(isnt) running"
        case .setup: return "\(names) \(isnt) set up on this Mac"
        case .permission: return "\(names) \(isnt) allowed yet"
        case .loginItems: return "\(names) \(one ? "is" : "are") turned off in Login Items"
        case .ok, .none: return ""
        }
    }

    /// The alert's text.
    public func message(vm: String) -> String {
        switch verdict {
        case .setup where fix == .updateApp:
            return "It has OmacVM \(vmVersion) from a newer app; this app is \(version). Update OmacVM first (Check for Updates), "
                + "then Update VM sets up \(names) on this Mac. Until then, \(features) do nothing."
        case .setup:
            let first: String
            switch why {
            case "other-mac": first = "\(names) \(isnt) set up for it on this Mac yet, so \(features) do nothing."
            case "too-old": first = "\(Self.capitalised(features)) \(one ? "stays" : "stay") empty until \(one ? "it is" : "they are") updated."
            case "not-running": first = "\(Self.capitalised(features)) do nothing until \(one ? "it runs" : "they run")."
            default: first = "\(Self.capitalised(features)) do nothing without \(them)."
            }
            var text = first + " Update VM sets \(them) up: it starts the VM without a window for a few minutes, then starts it as usual."
            let asking = helpers.filter { h in lines.contains { $0.name == h && $0.state == "missing" } }
                .compactMap { h in Self.asks(h).map { "\(h) (\($0))" } }
            if !asking.isEmpty { text += " macOS then asks you to allow \(Self.list(asking)): please allow \(asking.count == 1 ? "it" : "them")." }
            return text + "\n\nLater starts the VM as it is."
        case .permission:
            return "\(Self.capitalised(features)) need \(missing) for \(names). Turn \(them) on in System Settings › Privacy & Security; "
                + "\(one ? "it works" : "they work") within seconds, no restart needed.\n\nLater starts the VM as it is."
        case .loginItems:
            return "macOS doesn't start \(them): \(one ? "it is" : "they are") switched off in System Settings › General › Login Items & Extensions "
                + "(Allow in the Background). Turn \(names) on there; \(features) need \(them).\n\nLater starts the VM as it is."
        case .ok, .none:
            return ""
        }
    }

    /// The alert's and the notice's button.
    public var button: String {
        switch fix {
        case .updateVM: return "Update VM"
        case .updateApp: return "Check for Updates…"
        case .settings: return "Open System Settings"
        case .loginItems: return "Open Login Items"
        case .none: return ""
        }
    }

    /// The window's notice under the header.
    public func notice(vm: String) -> String {
        let features = Self.list(helpers.map(Self.servesShort))
        switch verdict {
        case .setup where fix == .updateApp:
            return "\(title(vm: vm)): it has OmacVM \(vmVersion), this app \(version). Update OmacVM, then Update VM sets up \(names) on this Mac."
        case .setup:
            return "\(title(vm: vm)): \(features) do nothing until Update VM sets up \(names)."
        case .permission:
            return "\(title(vm: vm)): \(features) wait for \(missing) (System Settings › Privacy & Security)."
        case .loginItems:
            return "\(title(vm: vm)): macOS doesn't start \(them), so \(features) do nothing."
        case .ok, .none:
            return ""
        }
    }

    /// The notice's (i): each helper the VM needs and how it is.
    public func info(vm: String) -> String {
        let rows = lines.map { "• \($0.name) (\(Self.serves($0.name))): \(Self.stateText($0))" }
        var text = "What \(vm) needs from this Mac:\n" + rows.joined(separator: "\n")
        if why == "other-mac" { text += "\n\nThe VM has another Mac's token, so the helpers here don't let it in." }
        return text + "\n\nCopied from another Mac? Update VM once sets it up here: it installs the helpers, gives the VM this Mac's token, "
            + "and macOS asks you to allow the helpers."
    }

    private static func stateText(_ h: Helper) -> String {
        switch h.state {
        case "ok", "starting": return "set up"
        case "waiting": return "macOS is asking for its permissions"
        case "permission": return "not allowed yet (\(h.detail.replacingOccurrences(of: "running, but ", with: "")))"
        case "missing": return "not installed"
        case "stopped": return "not running"
        case "disabled": return "off in Login Items"
        case "old": return "too old for this app"
        default: return h.detail
        }
    }

    /// The System Settings pane the button opens.
    public var settingsURL: String? {
        switch fix {
        case .settings:
            return "x-apple.systempreferences:com.apple.preference.security?"
                + (missing == "Input Monitoring" ? "Privacy_ListenEvent" : "Privacy_Accessibility")
        case .loginItems:
            return "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        default:
            return nil
        }
    }

    // MARK: Later, and the log

    /// What Later remembers per VM: this problem with this app version. The
    /// alert comes again when the problem or the app changes.
    public func laterKey(appVersion: String) -> String {
        "\(verdict.rawValue):\(fix.rawValue):\(helpers.joined(separator: "|"))@\(appVersion)"
    }

    /// For qemu.log ("OmacVM: Mac helpers: ...", which omacvm check can read).
    public var record: String {
        switch verdict {
        case .ok: return "ok (\(needed.joined(separator: ", ")))"
        case .none: return "none needed"
        case .setup: return "setup \(why) (\(helpers.joined(separator: ", "))), fix \(fix.rawValue)"
        case .permission: return "permission (\(helpers.joined(separator: ", ")): \(missing))"
        case .loginItems: return "login-items (\(helpers.joined(separator: ", ")))"
        }
    }

    /// The test hook's answer (OMACVM_TEST_HELPERS_ANSWER), or the person's:
    /// the button (fix) or Later.
    public enum Answer: String, Sendable { case fix, later }
}
