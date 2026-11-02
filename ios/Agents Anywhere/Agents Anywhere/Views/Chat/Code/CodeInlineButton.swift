import SwiftUI

/// The official inline capsule button, decoded from Claude 1.261023.20
/// (`ClaudeInlineButtonStyle<Capsule>`, style `.secondary`, size `.regular`).
///
/// R-T4 spec: transparent background, continuous capsule, `border300` 15%
/// stroke of two device pixels, 6 pt vertical / 14 pt horizontal padding,
/// a 72 pt minimum width applied *inside* the horizontal padding, 15 pt /
/// 550 / 21 pt label, `text100` ink, pressed opacity 0.7 with scale 0.98,
/// disabled opacity 0.75, a 44 pt minimum tap width, and a ring spinner that
/// replaces the label while loading. SwiftUI exposes no 550 weight preset;
/// `.semibold` is the closest.
struct CodeInlineButtonStyle: ButtonStyle {
    enum Size { case small, regular, large }

    var size: Size = .regular
    /// `AsyncButton`'s loading state: the label turns transparent (layout
    /// stays), a spinner overlays it and the button is disabled.
    var isLoading = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .callout) private var fontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 21

    private var verticalPadding: CGFloat {
        switch size {
        case .small, .regular: return 6
        case .large: return 12
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 12
        case .regular: return 14
        case .large: return 16
        }
    }

    private var minimumWidth: CGFloat? {
        switch size {
        case .small: return nil
        case .regular: return 72
        case .large: return 84
        }
    }

    private var ink: Color {
        CodePageTheme.text100Color.resolved(for: colorScheme)
    }

    private var stroke: Color {
        CodePageTheme.border300Color.resolved(for: colorScheme)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .frame(height: lineHeight)
            .opacity(isLoading ? 0 : 1)
            .foregroundStyle(ink)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: minimumWidth)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, horizontalPadding)
            .background(Color.clear)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: 2 / displayScale)
            }
            .contentShape(CodeMinimumTapTarget(minimumWidth: 44))
            .scaleEffect(configuration.isPressed ? 0.98 : 1, anchor: .center)
            .opacity(isEnabled ? 1 : 0.75)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(ink)
                }
            }
            .accessibilityValue(isLoading ? Text("Loading") : Text(verbatim: ""))
    }
}

/// The official footnote face: 13 pt relative to `.callout`, weight 400,
/// 18.2 pt line height (R-T2). `tone` selects the token the official uses for
/// that surface: `text500` for the detail-page footnote, `text300` for the
/// Read truncation note.
struct CodeFootnoteText: View {
    enum Tone { case footnote, readNote }

    let text: String
    var tone: Tone = .footnote

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var fontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 18.2

    private var color: Color {
        switch tone {
        case .footnote: return CodePageTheme.text500Color.resolved(for: colorScheme)
        case .readNote: return CodePageTheme.text300Color.resolved(for: colorScheme)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(color)
            // SwiftUI has no line-height property; the system font's default
            // line box is ~1.2 em, so this reaches the official 18.2 pt at
            // the 13 pt preset and keeps scaling with Dynamic Type.
            .lineSpacing(max(0, lineHeight - fontSize * 1.2))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `ClaudeDesignConstants.MinimumTapTarget`: a hit shape that widens the
/// rect to at least `minimumWidth` without constraining its height.
private struct CodeMinimumTapTarget: Shape {
    var minimumWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = max(rect.width, minimumWidth)
        return Path(CGRect(x: rect.midX - width / 2, y: rect.minY,
                           width: width, height: rect.height))
    }
}
