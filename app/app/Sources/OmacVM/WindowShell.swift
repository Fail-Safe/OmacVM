import AppKit
import OmacVMWindow
import SwiftUI

/// A section of the sidebar (the table of contents).
struct NavItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let rgb: UInt32
}

/// Every screen of the app's window: the header pinned at the top (under the
/// transparent title bar, beside the window's buttons), notices under it
/// (the update banner, a message), then the sidebar and the settings, which
/// scroll. With no sidebar items the content takes the whole width.
struct WindowShell<Header: View, Notices: View, Content: View>: View {
    var nav: [NavItem] = []
    @ViewBuilder var header: Header
    @ViewBuilder var notices: Notices
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(2)
            notices.zIndex(1)
            if nav.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, CGFloat(WindowLayout.contentInset))
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                SpyScroll(nav: nav) { content }
            }
        }
        .frame(width: CGFloat(WindowSize.width))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Look.window, ignoresSafeAreaEdges: [])
        .ignoresSafeArea()
    }
}

/// The header: the window's buttons' room, the app icon, the name with its
/// state and facts, and the buttons at the right.
struct WindowHeader<Icon: View, Trailing: View>: View {
    let title: String
    var pill: StatusPill? = nil
    var facts: String? = nil
    var factsInfo: String? = nil
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            // The close, minimise and zoom buttons (macOS draws them here).
            Color.clear.frame(width: 64, height: 1)
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)
                        .layoutProbe("header-title")
                    if let pill { pill.fixedSize() }
                }
                if let facts {
                    HStack(spacing: 5) {
                        Text(facts).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if let factsInfo { InfoButton(topic: "this VM", text: factsInfo).controlSize(.small) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing }.fixedSize()
        }
        .padding(.trailing, CGFloat(WindowLayout.inset))
        .frame(height: Look.headerHeight)
        .background(Look.header.gesture(WindowDragGesture()))
        .overlay(alignment: .bottom) { Rectangle().fill(Look.hairline).frame(height: 1) }
    }
}

/// A line under the header: a message (an error in red, else grey), with ×.
struct MessageStrip: View {
    let text: String
    var error = false
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(error ? Look.red : .secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide this message")
                    .accessibilityLabel("Hide this message")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(error ? Look.red.opacity(0.08) : Look.header, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(Look.hairline).frame(height: 1) }
        .layoutProbe("message")
    }
}

/// Where each section starts, below the top of the visible part.
private struct SectionTops: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// A section the sidebar can scroll to and marks while it is in view.
    func spySection(_ id: String) -> some View {
        self.id(id).background(GeometryReader { g in
            Color.clear.preference(key: SectionTops.self, value: [id: g.frame(in: .scrollView).minY])
        })
    }
}

/// The sidebar and the scrolling settings: a click in the sidebar scrolls to
/// its section; while the settings scroll, the sidebar marks the section in
/// view (ScrollSpy), and the last one at the end.
struct SpyScroll<Content: View>: View {
    let nav: [NavItem]
    @ViewBuilder var content: Content
    /// The window pictures: start scrolled to this section.
    @Environment(\.spyStart) private var start
    @State private var current = 0
    @State private var tops: [String: CGFloat] = [:]
    @State private var atEnd = false
    /// After a click: the clicked one stays marked while the scroll runs.
    @State private var pinnedUntil = Date.distantPast
    private static var top: String { "spy-top" }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                sidebar(proxy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        content
                    }
                        .padding(.horizontal, CGFloat(WindowLayout.contentInset))
                        .padding(.top, 10)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Under the header, never over it.
                .clipped()
                .onPreferenceChange(SectionTops.self) { t in
                    tops = t
                    spy()
                }
                .onAppear {
                    guard let start, let i = nav.firstIndex(where: { $0.id == start }) else { return }
                    current = i
                    pinnedUntil = .distantFuture
                    DispatchQueue.main.async { proxy.scrollTo(start, anchor: .top) }
                }
                .onScrollGeometryChange(for: Bool.self) { g in
                    ScrollSpy.atEnd(offset: Double(g.visibleRect.minY), visible: Double(g.containerSize.height),
                                    content: Double(g.contentSize.height))
                } action: { _, end in
                    atEnd = end
                    spy()
                }
            }
        }
    }

    private func spy() {
        guard Date() > pinnedUntil else { return }
        let i = ScrollSpy.current(tops: nav.map { Double(tops[$0.id] ?? .infinity) }, atEnd: atEnd)
        if i != current { current = i }
    }

    private func sidebar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(nav.enumerated()), id: \.element.id) { i, item in
                Button {
                    current = i
                    pinnedUntil = Date().addingTimeInterval(0.8)
                    // The first section: the very top, with the space above its title.
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(i == 0 ? Self.top : item.id, anchor: .top) }
                } label: {
                    HStack(spacing: 8) {
                        NavIcon(symbol: item.symbol, color: Color(rgb: item.rgb))
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundStyle(i == current ? Color.white : Color.primary)
                    .background(i == current ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == current ? [.isSelected] : [])
                .layoutProbe("nav-\(item.id)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: CGFloat(WindowSize.sidebar))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Look.sidebar, ignoresSafeAreaEdges: [])
        .overlay(alignment: .trailing) { Rectangle().fill(Look.hairline).frame(width: 1) }
    }
}

/// The sections of a VM's settings.
enum SettingsNav {
    static let items = [
        NavItem(id: "general", title: "General", symbol: "gearshape", rgb: 0x8E8E93),
        NavItem(id: "display", title: "Display", symbol: "display", rgb: 0x0A84FF),
        NavItem(id: "input", title: "Input", symbol: "keyboard", rgb: 0xFF9F0A),
        NavItem(id: "sharing", title: "Sharing & Devices", symbol: "globe", rgb: 0x2DB44E),
        NavItem(id: "storage", title: "Storage & Updates", symbol: "externaldrive", rgb: 0x5E5CE6),
    ]
}
