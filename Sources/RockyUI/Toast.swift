import SwiftUI

/// A toast's button: its title and what it does (CMT-05's Show opens the conversation a comment went to).
struct ToastAction {
    let title: String
    let run: @MainActor () -> Void
}

/// The window's one toast (GST-02, GST-03, ERR-01, CMT-05): a short line that fades in, stays 2.4 s and fades out; with
/// an action it stays 4 s, so there is time to click it. A new line replaces the one on screen and starts the time
/// over. `RootView` owns it and gives it to `AppModel.onToast`.
@MainActor
@Observable
final class ToastPresenter {
    private(set) var text: String?
    private(set) var action: ToastAction?
    private(set) var isShown = false
    @ObservationIgnored private var hide: Task<Void, Never>?

    static let duration: Duration = .milliseconds(2400)
    static let actionDuration: Duration = .seconds(4)

    func show(_ text: String, action: ToastAction? = nil) {
        self.text = text
        self.action = action
        isShown = true
        // VoiceOver reads it too: the toast takes no focus.
        AccessibilityNotification.Announcement(text).post()
        hide?.cancel()
        let duration = action == nil ? Self.duration : Self.actionDuration
        hide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Fades the toast out. Its button stays drawn while it fades, but a hidden toast takes no click (`ToastHost`).
    func dismiss() {
        hide?.cancel()
        hide = nil
        isShown = false
    }
}

/// Draws the toast over the whole window, like `MenuHost`, as the design's `.toast`: centered 52 points below the
/// window's top, on `panel` with a faint ring and a shadow, 12 `textSecondary`, fading in and out in 150 ms. A git
/// failure's few lines of stderr wrap under each other. Only a toast with an action takes clicks, on the toast itself:
/// its text button (12 medium) runs the action and closes it. Everything around it lets clicks through.
struct ToastHost: View {
    let presenter: ToastPresenter
    private static let top: CGFloat = 52

    var body: some View {
        VStack {
            if let text = presenter.text {
                HStack(spacing: 10) {
                    Text(text)
                        .font(.rocky(12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = presenter.action {
                        Button(action.title) {
                            presenter.dismiss()
                            action.run()
                        }
                        .font(.rocky(12, weight: .medium))
                        .buttonStyle(RockyTextButtonStyle(height: 22))
                        .fixedSize()
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, presenter.action == nil ? 12 : 6)
                .padding(.vertical, presenter.action == nil ? 8 : 5)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                .opacity(presenter.isShown ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: presenter.isShown)
                .allowsHitTesting(presenter.isShown && presenter.action != nil)
            }
        }
        // Caps what the line is offered, so a long one wraps; a short one keeps its own width.
        .frame(maxWidth: Zoom.shared(560))
        .padding(.top, Self.top)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}
