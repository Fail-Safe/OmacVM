import Foundation
import OmacVMWindow

// The settings 3.1 added to the window (the plan's shared contract; their
// behaviour lives with QEMU and OmacVM Gestures). AGENTS.md has the table of
// every setting, its key or file, its default and whether it is per VM.

extension Settings {
    /// Closing a running VM's window: shut it down (the default), keep it
    /// running, or ask (org.omacvm.app closeAction; QEMU's OMACVM_CLOSE_ACTION).
    static var closeAction: CloseAction {
        get { CloseAction.parse(UserDefaults.standard.object(forKey: CloseAction.key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: CloseAction.key) }
    }
}

/// Swipe out to macOS (org.omacvm.gestures SwipeOut, off by default), in
/// OmacVM Gestures' own settings domain like the escape combo (the test
/// identity's Gestures has its own: EscapeSetting.appDomain).
enum SwipeOutSetting {
    static func current(_ d: UserDefaults? = UserDefaults(suiteName: EscapeSetting.appDomain)) -> Bool {
        SwipeOut.isOn(stored: d?.object(forKey: SwipeOut.key))
    }

    static func set(_ on: Bool, _ d: UserDefaults? = UserDefaults(suiteName: EscapeSetting.appDomain)) {
        d?.set(on, forKey: SwipeOut.key)
    }
}
