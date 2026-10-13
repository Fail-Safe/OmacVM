import Foundation

/// What the plug-in shows, apart from the Dock (icon-tests).
public enum DockTileLook {
    /// The look stored for the app with this bundle id; nil: OmacVM's own
    /// (the bundle's icon).
    public static func stored(domain: String) -> IconTheme? {
        CFPreferencesAppSynchronize(domain as CFString)
        let value = CFPreferencesCopyAppValue(IconTheme.key as CFString, domain as CFString)
        let t = IconTheme.choice(stored: value)
        return t.isDefault ? nil : t
    }

    /// The bundle id of the app around the plug-in (APP.app/Contents/PlugIns/
    /// X.docktileplugin), read from its Info.plist: a renamed or relabeled
    /// copy keeps its own.
    public static func appID(plugIn: URL) -> String? {
        let app = plugIn.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app",
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
