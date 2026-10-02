import SwiftUI

struct StatusShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if active && !reduceMotion { content.modifier(ActiveStatusShimmer()) }
        else { content }
    }
}

/// A local compositor animation; no per-frame timeline/model publications.
struct ActiveStatusShimmer: ViewModifier {
    @State private var sweeps = false
    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.45), location: 0),
                    .init(color: .white.opacity(0.45), location: 0.35),
                    .init(color: .white, location: 0.5),
                    .init(color: .white.opacity(0.45), location: 0.65),
                    .init(color: .white.opacity(0.45), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 3)
                .offset(x: sweeps ? 0 : -geometry.size.width * 2)
            }
        }
        .onAppear {
            sweeps = false
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweeps = true }
        }
        .onDisappear { sweeps = false }
    }
}
