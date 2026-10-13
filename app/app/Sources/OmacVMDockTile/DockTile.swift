import AppKit
import OmacVMIcon

/// The app's Dock tile while it is not running: the icon's look the user
/// picked (appIconTheme in the app's own defaults), or the bundle's icon for
/// OmacVM's own look. While the app runs, its own icon is the tile's
/// (AppIcon.swift); this draws the same picture, so a pinned OmacVM keeps
/// its look when it quits, after a relaunch and after an update. The app
/// bundle is never changed (a custom icon on it would break `codesign
/// --verify --strict` and the Dock does not show it until it restarts).
///
/// macOS loads this plug-in (Contents/PlugIns/OmacVMDockTile.docktileplugin,
/// the app's NSDockTilePlugIn) into its Dock helper while the app is in the
/// Dock, running or not, next to other apps' plug-ins: it only reads one
/// preference and draws one picture, on the main thread.
@objc(OmacVMDockTilePlugIn)
final class OmacVMDockTilePlugIn: NSObject, NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var observing = false
    /// The app's bundle id: its defaults domain (a test copy has its own).
    private lazy var domain: String? = DockTileLook.appID(plugIn: Bundle(for: OmacVMDockTilePlugIn.self).bundleURL)

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        let center = DistributedNotificationCenter.default()
        if dockTile == nil {
            if observing { center.removeObserver(self) }
            observing = false
            return
        }
        if !observing, let domain {
            center.addObserver(self, selector: #selector(lookChanged(_:)),
                               name: Notification.Name(IconTheme.changedNotification), object: domain)
            observing = true
        }
        draw()
    }

    @objc private func lookChanged(_ note: Notification) {
        DispatchQueue.main.async { self.draw() }
    }

    private func draw() {
        guard let tile else { return }
        let look = domain.flatMap { DockTileLook.stored(domain: $0) }
        if let look {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = IconArt.image(look, size: 512)
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}
