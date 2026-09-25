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
        /// The panel's width; with `growsToFit`, its minimum.
        let width: CGFloat
        /// The panel is as wide as its widest row, and never narrower than `width` (HDR-04's Create PR menu).
        var growsToFit = false
        /// False: the content reaches the panel's edges, clipped to its shape (M2.8 Decision 7, the model menu's
        /// agent rail, `AGM-01`).
        var padded = true
        let content: AnyView
    }

    private(set) var open: OpenMenu?
    @ObservationIgnored private var escMonitor: Any?

    /// Every presenter, held weakly, so one that goes away with its view never counts as open. The settings panels'
    /// Esc monitors read `isAnyMenuOpen` from here, since `RootView` keeps its presenter in its state, out of their
    /// reach.
    private static let presenters = NSHashTable<MenuPresenter>.weakObjects()

    /// Whether a Rocky menu is open anywhere in the app. Esc then belongs to the menu alone: a settings panel under it
    /// stays open. The order AppKit runs the local key monitors in is not something to rely on, so the panels let Esc
    /// through while this is true, and the menu's own monitor closes the menu.
    static var isAnyMenuOpen: Bool {
        presenters.allObjects.contains { $0.open != nil }
    }

    init() {
        Self.presenters.add(self)
    }

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
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }
                    MenuPlacementLayout(anchor: anchor, placement: menu.placement, gap: Self.gap, margin: Self.margin) {
                        MenuPanel(width: menu.width, growsToFit: menu.growsToFit, padded: menu.padded) { menu.content }
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

/// Places the open menu's panel next to its control, from the panel's own size, so a panel that grows to fit its rows
/// lines up with its control as a fixed-width one does: below or above it with `gap` between them, on its leading or
/// trailing edge, and at least `margin` inside the window.
private struct MenuPlacementLayout: Layout {
    let anchor: CGRect
    let placement: MenuPlacement
    let gap: CGFloat
    let margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let size = panel.sizeThatFits(.unspecified)
        let leading = placement == .belowLeading || placement == .aboveLeading
        let below = placement == .belowLeading || placement == .belowTrailing
        let x = min(max(leading ? anchor.minX : anchor.maxX - size.width, margin), bounds.width - size.width - margin)
        let y = below ? anchor.maxY + gap : anchor.minY - gap - size.height
        panel.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// The panel every Rocky menu is drawn in: `width` wide, or with `growsToFit` as wide as its widest row and at least
/// `width`. Without `padded`, the content touches the panel's edges and is clipped to its rounded shape, so a fill of
/// its own (the model menu's agent rail) follows the corners.
struct MenuPanel<Content: View>: View {
    let width: CGFloat
    var growsToFit = false
    var padded = true
    @ViewBuilder let content: () -> Content

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12)
    }

    var body: some View {
        rows
            .font(.rocky(12))
            .padding(padded ? 6 : 0)
            .frame(width: growsToFit ? nil : width, alignment: .leading)
            .background(Theme.panel, in: Self.shape)
            .modifier(PanelClip(isClipped: !padded, shape: Self.shape))
            .overlay(Self.shape.strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rows: some View {
        if growsToFit {
            // The panel's padding is not zoomed, as in the fixed-width panel.
            MenuFittingColumn(minWidth: max(0, width - 12)) { content() }
        } else {
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }
}

/// Clips an unpadded panel's content to the panel's shape; a padded panel is left as every menu was.
private struct PanelClip: ViewModifier {
    let isClipped: Bool
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if isClipped {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

/// A growing menu's rows, one under the other, as wide as the widest row wants and at least `minWidth`, every row
/// stretched to that width so their hover fills line up. A row therefore never wraps its label (HDR-04).
private struct MenuFittingColumn: Layout {
    let minWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = columnWidth(subviews)
        let height = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in subviews {
            let height = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            row.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func columnWidth(_ subviews: Subviews) -> CGFloat {
        subviews.reduce(minWidth) { max($0, $1.sizeThatFits(.unspecified).width) }
    }
}

/// A control that opens a Rocky menu. `label` gets whether its menu is open, to light the control meanwhile.
struct MenuButton<Label: View, Content: View>: View {
    let id: String
    var placement: MenuPlacement = .belowLeading
    var width: CGFloat = 240
    /// The menu is as wide as its widest row, at least `width` (`MenuPresenter.OpenMenu.growsToFit`).
    var growsToFit = false
    /// False: no padding inside the panel (`MenuPresenter.OpenMenu.padded`).
    var padded = true
    @ViewBuilder let label: (_ isOpen: Bool) -> Label
    @ViewBuilder let content: () -> Content
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            presenter?.toggle(.init(
                id: id,
                anchor: frame,
                placement: placement,
                width: Zoom.shared(width),
                growsToFit: growsToFit,
                padded: padded,
                content: AnyView(content())
            ))
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


/// A menu row's icon, in an 18-point column. A row without one takes no column, so its title starts at the row's
/// leading padding (user decision, 2026-09-24): a menu whose rows have no icons has no empty gutter on its left. No
/// menu mixes rows with and without icons; one that did would need an empty column on the rows without, to keep the
/// titles in line.
enum MenuIcon {
    case none
    case symbol(String)
    case agent(AgentKind)
    /// An app's own icon, such as an editor's (`OPN-01`), drawn at 16 points in full color.
    case image(NSImage)

    /// Whether the row has the icon column.
    var hasColumn: Bool {
        if case .none = self { return false }
        return true
    }
}

/// One row of a Rocky menu: icon, title, optional detail line, shortcut or checkmark. Choosing it closes the menu.
/// `disabledReason` dims the row, makes it do nothing and becomes its tooltip (PR-05's Rebase).
struct MenuItem: View {
    let title: String
    var icon: MenuIcon = .none
    var detail: String?
    var shortcut: String?
    var isChecked = false
    /// An SF Symbol after the title, in `textTertiary`: "↗" on a row that opens the browser (HDR-04).
    var trailingSymbol: String?
    var isDestructive = false
    /// The detail line's size: 10 in most menus, 11.5 in the merge method menu (PR-05).
    var detailSize: CGFloat = 10
    var disabledReason: String?
    let action: () -> Void
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?

    var body: some View {
        PanelRow(isSelected: false) {
            presenter?.dismiss()
            action()
        } content: {
            if icon.hasColumn {
                iconView
                    .frame(width: Zoom.shared(18))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.rocky(detailSize)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let shortcut {
                Text(shortcut).foregroundStyle(Theme.textTertiary)
            }
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.rocky(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            if isChecked {
                Image(systemName: "checkmark").font(.rocky(10, weight: .semibold))
            }
        }
        .foregroundStyle(isDestructive ? Theme.danger : Theme.textPrimary)
        .disabled(disabledReason != nil)
        .opacity(disabledReason == nil ? 1 : 0.45)
        .optionalHelp(disabledReason)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .none: EmptyView()
        case .symbol(let name): Image(systemName: name).foregroundStyle(isDestructive ? Theme.danger : Theme.textSecondary)
        case .agent(let agent): AgentIcon(agent: agent, size: 14)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Zoom.shared(16), height: Zoom.shared(16))
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
