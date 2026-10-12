import AppKit
import OmacVMWindow
import SwiftUI

/// Under the header: a ready update (never while update checks are off,
/// unless a check by hand found it).
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        // Weekly checks on, or a check by hand in this session.
        let banner = updater.staged != nil && (updater.enabled || updater.lastOutcome != nil)
        if banner, let s = updater.staged {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(Product.name) \(s.version) is ready", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text(bannerText)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let n = s.notes { Button("What's New") { NSWorkspace.shared.open(n) } }
                    Button("Skip This Version") { updater.skip() }.disabled(updater.restarting)
                    Spacer()
                    if !updater.installWhenIdle && !updater.restarting {
                        Button("Update to \(s.version)…") { update(s.version) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.banner, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) { Rectangle().fill(Look.bannerLine).frame(height: 1) }
            .layoutProbe("update-banner")
        }
    }

    private var bannerText: String {
        if updater.restarting { return "The VM shuts down for the update; it starts again with the new version." }
        if updater.installWhenIdle {
            return "You have \(updater.currentVersion). It goes in once the VM has shut down; your VMs are not changed."
        }
        if updater.runningVM() != nil {
            return "You have \(updater.currentVersion). Your VM shuts down cleanly, \(Product.name) updates and restarts, then starts the VM again."
        }
        return "You have \(updater.currentVersion). \(Product.name) restarts with the new version; your VMs are not changed."
    }

    /// One confirm, then the update: with a VM restart when this launcher runs the VM.
    private func update(_ version: String) {
        let current = updater.currentVersion
        if updater.runningVM() != nil {
            guard Updater.restartAlert(version, current: current).runModal() == .alertFirstButtonReturn else { return }
            Task { await updater.restartFromMac() }
            return
        }
        let alert = Updater.checkAlert(.ready(version), current: current, busy: updater.busyNow)
        if alert.runModal() == .alertFirstButtonReturn { updater.install() }
    }
}
