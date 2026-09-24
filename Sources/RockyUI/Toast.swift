import SwiftUI

/// The window's one toast (GST-02, GST-03, ERR-01): a short line that fades in, stays 2.4 s and fades out. A new line
/// replaces the one on screen and starts the time over. `RootView` owns it and gives it to `AppModel.onToast`.
@MainActor
@Observable
final class ToastPresenter {
    private(set) var text: String?
    private(set) var isShown = false
    @ObservationIgnored private var hide: Task<Void, Never>?

    static let duration: Duration = .milliseconds(2400)

    func show(_ text: String) {
        self.text = text
        isShown = true
        // VoiceOver reads it too: the toast takes no focus.
        AccessibilityNotification.Announcement(text).post()
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.isShown = false
        }
    }
}

/// Draws the toast over the whole window, like `MenuHost`, as the design's `.toast`: centered 52 points below the
/// window's top, on `panel` with a faint ring and a shadow, 12 `textSecondary`, fading in and out in 150 ms. A git
/// failure's few lines of stderr wrap under each other. It never takes a click.
struct ToastHost: View {
    let presenter: ToastPresenter
    private static let top: CGFloat = 52

    var body: some View {
        VStack {
            if let text = presenter.text {
                Text(text)
                    .font(.rocky(12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                    .opacity(presenter.isShown ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: presenter.isShown)
            }
        }
        // Caps what the line is offered, so a long one wraps; a short one keeps its own width.
        .frame(maxWidth: Zoom.shared(560))
        .padding(.top, Self.top)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
