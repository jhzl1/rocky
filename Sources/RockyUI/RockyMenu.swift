import AppKit
import RockyKit
import SwiftUI

/// Rocky draws its own menus instead of the system's, all in the model picker's style (user decision,
/// 2026-09-23): a dark rounded panel with a hairline border, rows lit on hover, an icon and a shortcut per row.
/// `MenuPresenter` holds the one open menu; `MenuHost`, on top of the whole window, draws it next to the control
/// that opened it and closes it on a click outside it or on Esc. A menu that lists `keyActions` also takes ↑/↓ and
/// Return (Decision 11 of M2.9, TSK-04's input pickers).
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
        /// The rows ↑/↓ move through and Return picks, in the order `MenuItem(keyIndex:)` numbers them; empty for a
        /// menu of the mouse alone.
        var keyActions: [@MainActor () -> Void] = []
        /// The row lit when the menu opens, so Return takes it: TSK-04's default.
        var initialHighlight: Int?
        /// Called when the menu closes without a pick: Esc, a click outside, another menu. TSK-04's Esc cancels the run.
        var onCancel: (@MainActor () -> Void)?
        let content: AnyView
    }

    private(set) var open: OpenMenu?
    /// The `keyIndex` of the row ↑/↓ lit, or the pointer last entered.
    private(set) var highlighted: Int?
    @ObservationIgnored private var keyMonitor: Any?

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
        let replaced = open
        open = menu
        highlighted = menu.initialHighlight
        if let replaced, replaced.id != menu.id { replaced.onCancel?() }
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    func toggle(_ menu: OpenMenu) {
        if isOpen(menu.id) { dismiss() } else { show(menu) }
    }

    /// Keeps an open menu next to its control when the layout moves.
    func move(_ id: String, to anchor: CGRect) {
        if open?.id == id { open?.anchor = anchor }
    }

    /// Closes the menu without a pick: its `onCancel` runs.
    func dismiss() {
        let closed = open
        open = nil
        highlighted = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        closed?.onCancel?()
    }

    /// A row was chosen: the menu closes, and its `onCancel` does not run.
    func dismissPicking() {
        open?.onCancel = nil
        dismiss()
    }

    /// The pointer entered a row that takes the keyboard: one row is lit, the keys go on from it.
    func highlight(_ index: Int) {
        guard open?.keyActions.indices.contains(index) == true else { return }
        highlighted = index
    }

    /// Esc closes any menu; ↑/↓ and Return belong to a menu with `keyActions`, whatever has the keyboard behind it.
    private func handle(_ event: NSEvent) -> Bool {
        guard let menu = open else { return false }
        if event.keyCode == 53 {   // Esc
            dismiss()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !menu.keyActions.isEmpty, modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126:   // ↓, ↑
            let count = menu.keyActions.count
            let down = event.keyCode == 125
            highlighted = highlighted.map { ($0 + (down ? 1 : count - 1)) % count } ?? (down ? 0 : count - 1)
            return true
        case 36, 76:   // Return, Enter
            guard let highlighted, menu.keyActions.indices.contains(highlighted) else { return true }
            let action = menu.keyActions[highlighted]
            dismissPicking()
            action()
            return true
        default:
            return false
        }
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
    /// A bundled mark drawn as a template at 14 points in the menu's icon color, as a symbol is: GitHub's (`GHL-01`).
    case template(NSImage)

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
    /// The detail line's size: 10 in most menus, 11.5 in the merge method menu (PR-05) and the Run menu (TSK-02).
    var detailSize: CGFloat = 10
    var disabledReason: String?
    /// TSK-02: a 6-point `success` dot before the right end, for an item that is running.
    var isRunning = false
    /// Its place among the rows ↑/↓ move through (`MenuPresenter.OpenMenu.keyActions`), which lights it while it is
    /// the highlighted one.
    var keyIndex: Int?
    let action: () -> Void
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?

    var body: some View {
        PanelRow(isSelected: false, isHighlighted: keyIndex != nil && presenter?.highlighted == keyIndex) {
            presenter?.dismissPicking()
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
            if isRunning {
                Circle()
                    .fill(Theme.success)
                    .frame(width: Zoom.shared(6), height: Zoom.shared(6))
                    .accessibilityLabel("Running")
            }
            if isChecked {
                Image(systemName: "checkmark").font(.rocky(10, weight: .semibold))
            }
        }
        .foregroundStyle(isDestructive ? Theme.danger : Theme.textPrimary)
        .disabled(disabledReason != nil)
        .opacity(disabledReason == nil ? 1 : 0.45)
        .optionalHelp(disabledReason)
        .onHover { inside in
            if inside, let keyIndex { presenter?.highlight(keyIndex) }
        }
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
        case .template(let image):
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(isDestructive ? Theme.danger : Theme.textSecondary)
                .frame(width: Zoom.shared(14), height: Zoom.shared(14))
        }
    }
}

/// A clickable row of a menu panel, lit on hover like Conductor's, and while the keys highlight it (Decision 11 of M2.9)
/// as much as on hover.
struct PanelRow<Content: View>: View {
    let isSelected: Bool
    var isHighlighted = false
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
                    Color.white.opacity(hovering || isHighlighted ? 0.08 : (isSelected ? 0.04 : 0)),
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
    /// 10 in most menus; 10.5 for the Run menu's "Tasks" and an input's caption (TSK-02, TSK-04).
    var size: CGFloat = 10

    var body: some View {
        Text(title)
            .font(.rocky(size, weight: .medium))
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
    /// `isEnabled` false takes no right-click, with the same views, so turning it off never rebuilds what it wraps.
    func rockyContextMenu<Content: View>(
        id: String,
        width: CGFloat = 220,
        isEnabled: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(RockyContextMenu(id: id, width: width, isEnabled: isEnabled, menu: content))
    }
}

private struct RockyContextMenu<MenuContent: View>: ViewModifier {
    let id: String
    let width: CGFloat
    let isEnabled: Bool
    let menu: () -> MenuContent
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .overlay {
                RightClickCatcher { point in
                    guard isEnabled else { return }
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
