import SwiftUI
import UIKit

/// The cold-open spinner for the chat page.
///
/// Mirrors the official iOS chat page (1.261109.19
/// `ClaudeCoreUI.LoadingSpinnerOverlayView`): the spinner waits 0.25 s before
/// it appears so a fast open never flashes it, then cross-fades with
/// `Animation.easeInOut` (SwiftUI's default 0.35 s). The official transcript
/// list uses the same 0.25 s delay.
///
/// The surrounding `SessionChatView.openingMask` owns the opaque page-colored
/// cover (it must hide the unpositioned transcript); this view only owns the
/// spinner's delayed reveal.
struct OpeningSpinner: View {
    /// `LoadingSpinnerOverlayView(delay:)` at the chat page and the transcript
    /// list: 0.25 s.
    static let revealDelay: Duration = .seconds(0.25)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible {
                ProgressView()
                    .progressViewStyle(.circular)
                    .accessibilityLabel(String(localized: "正在加载会话"))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: isVisible)
        .task {
            do { try await Task.sleep(for: Self.revealDelay) } catch { return }
            isVisible = true
        }
    }
}

#Preview {
    OpeningSpinner()
        .padding(40)
        .background(Color(uiColor: .systemBackground))
}
