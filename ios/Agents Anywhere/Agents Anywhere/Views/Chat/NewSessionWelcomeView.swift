import SwiftUI

/// The new-session empty state: the Creed crystal globe with the official
/// "build with {runtime}" copy underneath. Only the runtime name is a link —
/// underlined, opening the device & agent picker; the rest of the copy is not
/// tappable (pp 2026-11-13).
struct NewSessionWelcomeView: View {
    let agentName: String?
    let onChooseTarget: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var globeSize: CGFloat = 220

    private var agent: String { agentName ?? String(localized: "Agent") }
    private var title: AttributedString {
        copy(String(localized: "使用 \(agent) 进行构建"),
             base: .primary, name: agent, nameColor: .primary)
    }
    private var detail: AttributedString {
        copy(String(localized: "\(agent) 直接在您的代码库中与您协作，帮助您添加功能、修复 bug 和解释代码。"),
             base: ChatPalette.iconSecondary.color,
             name: agent,
             nameColor: ChatPalette.iconSecondary.color)
    }

    var body: some View {
        VStack(spacing: 18) {
            CrystalGlobeView(diameter: min(globeSize, 280))
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
