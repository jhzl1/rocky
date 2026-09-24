import AppKit
import SwiftUI

/// The line between the chat and the terminal panel (TERM-01): a 1-point hairline with a 9-point invisible handle
/// that drags the panel's height, with the up-down resize cursor. `SidebarDivider` turned 90°. While the panel is
/// empty or folded there is no handle, so the line does not look draggable when dragging would do nothing.
struct PanelDivider: View {
    /// The panel's height, bar included: dragging up makes it taller.
    @Binding var height: Double
    /// From the panel's minimum to what leaves the chat its minimum; `WorkspaceDetailView` works it out from the
    /// window's height.
    let range: ClosedRange<Double>
    let isResizable: Bool
    @State private var heightAtDragStart: Double?
    @State private var showsResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .overlay {
                if isResizable {
                    Color.clear
                        .frame(height: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in setResizeCursor(inside) }
                        .onDisappear { setResizeCursor(false) }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = heightAtDragStart ?? clamped(height)
                                    heightAtDragStart = start
                                    height = clamped(start - drag.translation.height)
                                }
                                .onEnded { _ in heightAtDragStart = nil }
                        )
                }
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Pushes the cursor once and pops only what it pushed. The handle can go away under the pointer (⌘J folds the
    /// panel), and SwiftUI then reports no hover exit, so `onDisappear` pops it instead.
    private func setResizeCursor(_ on: Bool) {
        guard on != showsResizeCursor else { return }
        if on { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        showsResizeCursor = on
    }
}

/// The line between the conversation and the right panel (PNL-01): `PanelDivider` turned 90°, a 1-point hairline on
/// the sidebar's color, like the panel's own lines, with a 9-point handle that drags the panel's width and shows the
/// left-right resize cursor. Dragging left widens the panel. The width does not follow the zoom.
struct ColumnDivider: View {
    /// The panel's width, right of the line.
    @Binding var width: Double
    /// PNL-01's 280–480, narrowed by `WorkspaceDetailView` so the conversation keeps its minimum.
    let range: ClosedRange<Double>
    @State private var widthAtDragStart: Double?
    @State private var showsResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            // Only its own bounds, from the window's top (LAY-01), as `RightPanel`'s background.
            .background(Color.rockySidebar, ignoresSafeAreaEdges: [])
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in setResizeCursor(inside) }
                    .onDisappear { setResizeCursor(false) }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? clamped(width)
                                widthAtDragStart = start
                                width = clamped(start - drag.translation.width)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// As `PanelDivider`'s: ⌥⌘B or the panel toggle can hide the line under the pointer.
    private func setResizeCursor(_ on: Bool) {
        guard on != showsResizeCursor else { return }
        if on { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        showsResizeCursor = on
    }
}
