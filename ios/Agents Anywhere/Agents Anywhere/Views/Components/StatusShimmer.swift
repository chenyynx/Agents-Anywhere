import SwiftUI

struct StatusShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if active && !reduceMotion {
                // [E] The official shimmer enters/leaves with an opacity
                // transition under `Animation.default`
                // (EVIDENCE/round19/motion.md §P2-7).
                content.modifier(ActiveStatusShimmer())
                    .transition(.opacity)
            } else {
                content
            }
        }
        .animation(.default, value: active)
    }
}

/// The official `ShimmerView` motion: a 2.0 s linear sweep, two tiled copies
/// of a `[colour @0.2, colour, colour @0.2]` gradient
/// (`EVIDENCE/round19/motion.md §P2-6`; KeyframeAnimator 0→1 repeating,
/// `LinearKeyframe(value: 1.0, duration: 2.0, .linear)`).
///
/// The gradient colour is the official `ShimmerView.shimmerColor`, which is
/// still UNKNOWN; white is the compositing mask value (only its alpha profile
/// matters here).
struct ActiveStatusShimmer: ViewModifier {
    @State private var progress: CGFloat = 0

    private static let period: Double = 2.0
    private static let edgeOpacity: Double = 0.2

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                let width = geometry.size.width
                let gradient = LinearGradient(stops: [
                    .init(color: .white.opacity(Self.edgeOpacity), location: 0),
                    .init(color: .white, location: 0.5),
                    .init(color: .white.opacity(Self.edgeOpacity), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                ZStack {
                    gradient
                        .frame(width: width)
                        .offset(x: (progress - 1) * width)
                    gradient
                        .frame(width: width)
                        .offset(x: progress * width)
                }
            }
        }
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: Self.period)
                .repeatForever(autoreverses: false)) {
                progress = 1
            }
        }
        .onDisappear { progress = 0 }
    }
}
