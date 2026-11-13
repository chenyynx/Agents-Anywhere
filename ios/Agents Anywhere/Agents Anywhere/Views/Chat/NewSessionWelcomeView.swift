import SwiftUI

/// The new-session empty state: the Creed crystal globe with the official
/// "build with {runtime}" copy underneath. Only the runtime name is a link —
/// underlined, opening the device & agent picker; the rest of the copy is not
/// tappable (pp 2026-11-13).
struct NewSessionWelcomeView: View {
    let agentName: String?
    let onChooseTarget: () -> Void
    /// While the composer is editing the page keeps the globe small, so the
    /// copy fits above the workspace button and keyboard instead of sliding
    /// under them.
    var compact = false
    @ScaledMetric(relativeTo: .largeTitle) private var globeSize: CGFloat = 220

    private var agent: String { agentName ?? String(localized: "Agent") }
    private var title: AttributedString {
        copy(String(localized: "使用 \(agent) 进行构建"),
             base: .primary, name: agent, nameColor: .primary)
    }
    private var detail: AttributedString {
        let ink = ChatPalette.text.color.opacity(0.72)
        return copy(String(localized: "\(agent) 直接在您的代码库中与您协作，帮助您添加功能、修复 bug 和解释代码。"),
                    base: ink, name: agent, nameColor: ink)
    }

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            CrystalGlobeView(diameter: compact ? min(globeSize * 0.45, 110)
                                                : min(globeSize, 280))
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Official text column: about 291 pt of copy, so the body wraps
            // after “添加” like the reference (pp 2026-11-13).
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "aa", url.host == "choose-target" else {
                return .systemAction
            }
            onChooseTarget()
            return .handled
        })
    }

    /// The runtime name is the only underlined, tappable run. The localized
    /// sentence decides where the name sits, so word order stays correct in
    /// every language.
    private func copy(_ text: String,
                      base: Color,
                      name: String,
                      nameColor: Color) -> AttributedString {
        guard let range = text.range(of: name) else {
            var whole = AttributedString(text)
            whole.foregroundColor = base
            return whole
        }
        var prefix = AttributedString(String(text[..<range.lowerBound]))
        prefix.foregroundColor = base
        var nameText = AttributedString(name)
        nameText.foregroundColor = nameColor
        nameText.underlineStyle = Text.LineStyle(pattern: .solid, color: nameColor)
        nameText.link = URL(string: "aa://choose-target")
        var suffix = AttributedString(String(text[range.upperBound...]))
        suffix.foregroundColor = base
        return prefix + nameText + suffix
    }
}
