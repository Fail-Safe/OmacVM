import Foundation

/// Keyboard sharing apps (#350, @javierburongarcia): Synergy, Deskflow,
/// Barrier or Input Leap tap the keys at the head of macOS's event tap chain,
/// as QEMU's full grab does, and the newest tap runs first: a VM started
/// after the sharing app took the keys while the pointer was on the other
/// computer. Hidden, off by default:
///   defaults write org.omacvm.app shareKeyboard -bool true
/// QEMU then puts its tap at the end of the chain (OMACVM_KEYS_LAST=1,
/// omacvm-cocoa-keys-last.patch), from the VM's next start; OmacVM Gestures
/// and the Bridge read the same key for their own taps.
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public enum ShareKeyboard {
    public static let key = "shareKeyboard"
    public static let variable = "OMACVM_KEYS_LAST"

    /// The setting as the app reads it.
    public static func isOn(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }

    /// QEMU's environment for one start: the variable with the setting on,
    /// none without (also not one the app itself was started with).
    public static func apply(_ on: Bool, to env: inout [String: String]) {
        if on { env[variable] = "1" } else { env.removeValue(forKey: variable) }
    }
}
