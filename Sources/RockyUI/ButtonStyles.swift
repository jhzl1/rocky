import SwiftUI

extension View {
    /// The pointing hand on everything that does something on click (CUR-01, user decision 2026-09-23: a departure
    /// from macOS, which keeps the arrow on buttons). Not on text fields, the terminal or the dividers.
    func clickable() -> some View {
        pointerStyle(.link)
    }
}

/// A square icon button: no fill at rest and the icon in `textSecondary`; on hover `fillIconHover` and
/// `textPrimary`; pressed `fillPressed` (CUR-02). Sizes 28, 22 (rows, headers, the panel bar), 18 (inside the search
/// field) and 16 (tab closes), through the zoom.
struct RockyIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        RockyIconButton(configuration: configuration, size: size)
    }

    private struct RockyIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        /// TOK-02: 6 for 28, 5 for 22, 4 below.
        private var radius: CGFloat {
            size >= 28 ? 6 : size >= 22 ? 5 : 4
        }

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: Zoom.shared(size), height: Zoom.shared(size))
                .background(
                    configuration.isPressed ? Theme.fillPressed : hovering && isEnabled ? Theme.fillIconHover : .clear,
                    in: RoundedRectangle(cornerRadius: radius)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// A text button that looks like an icon button: no fill at rest, a fill on hover (the sidebar footer's "Add
/// repository", the panel's "New terminal").
struct RockyTextButtonStyle: ButtonStyle {
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        RockyTextButton(configuration: configuration, height: height)
    }

    private struct RockyTextButton: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: Zoom.shared(height))
                .background(
                    configuration.isPressed ? Theme.fillPressed : hovering && isEnabled ? Theme.fillIconHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// A filled button (Run, Restart, the empty-state button): `fillButton`, hover `fillButtonHover`, pressed white
/// 16 %; 26 points high, radius 6 (TB-04).
struct RockyFilledButtonStyle: ButtonStyle {
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        RockyFilledButton(configuration: configuration, height: height)
    }

    private struct RockyFilledButton: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: Zoom.shared(height))
                .background(
                    configuration.isPressed ? Theme.fillButtonPressed : hovering && isEnabled ? Theme.fillButtonHover : Theme.fillButton,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}
