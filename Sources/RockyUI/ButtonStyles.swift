import SwiftUI

extension View {
    /// The pointing hand on everything that does something on click (CUR-01, user decision 2026-09-23: a departure
    /// from macOS, which keeps the arrow on buttons). Not on text fields, the terminal or the dividers.
    func clickable() -> some View {
        pointerStyle(.link)
    }
}

/// A square icon button: no fill at rest and the icon in `textSecondary`; on hover `fillIconHover` and
/// `textPrimary`; pressed `fillPressed` (CUR-02). `isOn` lights a toggle while what it shows is open: `fillSelected`
/// and `textPrimary` (PNL-02's panel toggle). Sizes 28, 22 (rows, headers, the panel bar), 18 (inside the search
/// field) and 16 (tab closes), through the zoom.
struct RockyIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        RockyIconButton(configuration: configuration, size: size, isOn: isOn)
    }

    private struct RockyIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        /// TOK-02: 6 for 28, 5 for 22, 4 below.
        private var radius: CGFloat {
            size >= 28 ? 6 : size >= 22 ? 5 : 4
        }

        /// A lit toggle keeps `fillSelected` on hover, like the mock's `.icon-btn.on`.
        private var fill: Color {
            if configuration.isPressed { return Theme.fillPressed }
            if isOn { return Theme.fillSelected }
            return hovering && isEnabled ? Theme.fillIconHover : .clear
        }

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .foregroundStyle((hovering || isOn) && isEnabled ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: Zoom.shared(size), height: Zoom.shared(size))
                .background(fill, in: RoundedRectangle(cornerRadius: radius))
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

/// An outlined button on `panel` (the pull request's Save, a comment's Add to chat): 22 points high, radius 5, a
/// 1-point white border at 14 %, 28 % on hover (the GitHub panel's `.outline-btn`).
struct RockyOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        RockyOutlineButton(configuration: configuration, height: height)
    }

    private struct RockyOutlineButton: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: Zoom.shared(height))
                .background(configuration.isPressed ? Theme.fillPressed : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.white.opacity(hovering && isEnabled ? 0.28 : 0.14))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// A white filled button for a view's one primary action (M3's "white filled": the comment box's Send, CMT-02): white
/// with #111316 text, #DADDE1 on hover; 26 points high, padding 10, radius 6. 45 % when disabled.
struct RockyPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        RockyPrimaryButton(configuration: configuration, height: height)
    }

    private struct RockyPrimaryButton: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private static let text = Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x16 / 255)
        private static let hoverFill = Color(red: 0xDA / 255, green: 0xDD / 255, blue: 0xE1 / 255)

        var body: some View {
            configuration.label
                .foregroundStyle(Self.text)
                .padding(.horizontal, 10)
                .frame(height: Zoom.shared(height))
                .background(
                    (configuration.isPressed || (hovering && isEnabled)) ? Self.hoverFill : Color.white,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// A filled button (Restart, the empty-state button, the terminal bar's Run): `fillButton`, hover `fillButtonHover`,
/// pressed white 16 %; 26 points high, padding 10, radius 6 (TB-04). The terminal bar's Run is 24 high, padding 8,
/// radius 5 (LAY-01).
struct RockyFilledButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 10
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        RockyFilledButton(configuration: configuration, height: height, horizontalPadding: horizontalPadding, cornerRadius: cornerRadius)
    }

    private struct RockyFilledButton: View {
        let configuration: Configuration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, horizontalPadding)
                .frame(height: Zoom.shared(height))
                .background(
                    configuration.isPressed ? Theme.fillButtonPressed : hovering && isEnabled ? Theme.fillButtonHover : Theme.fillButton,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

extension View {
    /// A text field's placeholder drawn by SwiftUI, in place of the field's own `prompt`: AppKit draws that one through
    /// the field editor once the field has the keyboard, 1 point higher, so it jumped on focus (user report,
    /// 2026-09-24). Give the field an empty prompt, and put this after its font so the two match.
    func stablePlaceholder(_ text: String, isVisible: Bool) -> some View {
        overlay(alignment: .leading) {
            if isVisible {
                Text(text)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
