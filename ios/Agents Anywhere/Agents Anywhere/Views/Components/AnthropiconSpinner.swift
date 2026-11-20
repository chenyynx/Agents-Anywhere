import SwiftUI

/// The official running glyph: an open ring that spins (pp 2026-11-20). The
/// system `ProgressView` draws a different family (the iOS petal spinner),
/// which read as foreign next to the Anthropicon rows.
struct AnthropiconSpinner: View {
    var size: CGFloat = 16
    /// One full turn. The official cadence is not documented; 0.9 s keeps the
    /// ring legible at 14 pt without strobing.
    var period: Double = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        AppSymbol("anthropicon.spinner", size: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: period).repeatForever(autoreverses: false)
                ) {
                    angle = 360
                }
            }
            .accessibilityHidden(true)
    }
}
