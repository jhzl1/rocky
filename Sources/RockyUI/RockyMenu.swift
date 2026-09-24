import AppKit
import RockyKit
import SwiftUI

/// Rocky draws its own menus instead of the system's, all in the model picker's style (user decision,
/// 2026-09-23): a dark rounded panel with a hairline border, rows lit on hover, an icon and a shortcut per row.
/// `MenuPresenter` holds the one open menu; `MenuHost`, on top of the whole window, draws it next to the control
/// that opened it and closes it on a click outside it or on Esc.
@MainActor
@Observable
final class MenuPresenter {
    struct OpenMenu {
        let id: String
        var anchor: CGRect
        let placement: MenuPlacement
        let width: CGFloat
        let content: AnyView
    }

    private(set) var open: OpenMenu?
    @ObservationIgnored private var escMonitor: Any?

    func isOpen(_ id: String) -> Bool {
        open?.id == id
    }

    func show(_ menu: OpenMenu) {
        open = menu
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }
    }

    func toggle(_ menu: OpenMenu) {
        if isOpen(menu.id) { dismiss() } else { show(menu) }
    }

    /// Keeps an open menu next to its control when the layout moves.
    func move(_ id: String, to anchor: CGRect) {
        if open?.id == id { open?.anchor = anchor }
    }

    func dismiss() {
        open = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}

/// Which side of its control a menu opens on, and which of the control's edges it lines up with.
enum MenuPlacement {
    case belowLeading, belowTrailing, aboveLeading, aboveTrailing
}

/// Draws the open menu over the whole window. A transparent layer under the panel takes the click that closes it,
/// as a system menu does.
struct MenuHost: View {
    let presenter: MenuPresenter
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let menu = presenter.open {
                // Anchors are window coordinates (`.global`). A named space on RootView was not used: views laid out
                // under the title bar measured 28 points off in it, and views inside the terminal split could not
                // reach it at all.
                let origin = proxy.frame(in: .global).origin
                let anchor = menu.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let leading = menu.placement == .belowLeading || menu.placement == .aboveLeading
                let x = min(max(leading ? anchor.minX : anchor.maxX - menu.width, Self.margin), proxy.size.width - menu.width - Self.margin)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }
                    switch menu.placement {
                    case .belowLeading, .belowTrailing:
                        MenuPanel(width: menu.width) { menu.content }
                            .offset(x: x, y: anchor.maxY + Self.gap)
                    case .aboveLeading, .aboveTrailing:
                        MenuPanel(width: menu.width) { menu.content }
                            .frame(height: max(0, anchor.minY - Self.gap), alignment: .bottom)
                            .offset(x: x)
                    }
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // With no menu open, clicks reach the window under it.
        .allowsHitTesting(presenter.open != nil)
        .animation(.easeOut(duration: 0.12), value: presenter.open?.id)
    }
}

/// The panel every Rocky menu is drawn in.
struct MenuPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .font(.rocky(12))
            .padding(6)
            .frame(width: width, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A control that opens a Rocky menu. `label` gets whether its menu is open, to light the control meanwhile.
struct MenuButton<Label: View, Content: View>: View {
    let id: String
    var placement: MenuPlacement = .belowLeading
    var width: CGFloat = 240
    @ViewBuilder let label: (_ isOpen: Bool) -> Label
    @ViewBuilder let content: () -> Content
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            presenter?.toggle(.init(id: id, anchor: frame, placement: placement, width: Zoom.shared(width), content: AnyView(content())))
        } label: {
            label(presenter?.isOpen(id) ?? false)
        }
        .buttonStyle(.plain)
        .clickable()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            frame = newFrame
            presenter?.move(id, to: newFrame)
        }
    }
}


enum MenuIcon {
    case none
    case symbol(String)
    case agent(AgentKind)
}

/// One row of a Rocky menu: icon, title, optional detail line, shortcut or checkmark. Choosing it closes the menu.
struct MenuItem: View {
    let title: String
    var icon: MenuIcon = .none
    var detail: String?
    var shortcut: String?
    var isChecked = false
    var isDestructive = false
    let action: () -> Void
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?

    var body: some View {
        PanelRow(isSelected: false) {
            presenter?.dismiss()
            action()
        } content: {
            iconView
                .frame(width: Zoom.shared(18))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.rocky(10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let shortcut {
                Text(shortcut).foregroundStyle(Theme.textTertiary)
            }
            if isChecked {
                Image(systemName: "checkmark").font(.rocky(10, weight: .semibold))
            }
        }
        .foregroundStyle(isDestructive ? Theme.danger : Theme.textPrimary)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .none: Color.clear.frame(height: 1)
        case .symbol(let name): Image(systemName: name).foregroundStyle(isDestructive ? Theme.danger : Theme.textSecondary)
        case .agent(let agent): AgentIcon(agent: agent, size: 14)
        }
    }
}

/// A clickable row of a menu panel, lit on hover like Conductor's.
struct PanelRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10, content: content)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(hovering ? 0.08 : (isSelected ? 0.04 : 0)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { hovering = $0 }
    }
}

struct MenuSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.rocky(10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
    }
}

extension View {
    /// A right-click (or Control-click) menu drawn by Rocky, opened where the pointer is.
    func rockyContextMenu<Content: View>(id: String, width: CGFloat = 220, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(RockyContextMenu(id: id, width: width, menu: content))
    }
}

private struct RockyContextMenu<MenuContent: View>: ViewModifier {
    let id: String
    let width: CGFloat
    let menu: () -> MenuContent
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .overlay {
                RightClickCatcher { point in
                    let anchor = CGRect(x: frame.minX + point.x, y: frame.minY + point.y, width: 0, height: 0)
                    presenter?.show(.init(id: id, anchor: anchor, placement: .belowLeading, width: Zoom.shared(width), content: AnyView(menu())))
                }
            }
    }
}

/// Takes only right-clicks and Control-clicks: every other event goes through to the views under it.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: (CGPoint) -> Void = { _ in }

        /// Top-left origin, like SwiftUI, so a click's point adds straight onto the SwiftUI frame.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            onRightClick(convert(event.locationInWindow, from: nil))
        }
    }
}
