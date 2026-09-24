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
