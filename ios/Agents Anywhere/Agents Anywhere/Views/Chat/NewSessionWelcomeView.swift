import SwiftUI

/// The new-session empty state, matched to the official Claude chat page
/// (pp 2026-11-17): the Claude mark, a time-of-day greeting carrying the
/// account's display name, and the plan pill underneath.
///
/// Measurements are off the 3× capture: mark 30 pt (#CC785C), greeting 20 pt in
/// Anthropic Serif (#383835), pill 36 pt tall on #F0EFEC with a 12 pt label
/// (regular #52514E, "Upgrade" semibold #0B0B0B). The Chinese resolves to the
/// system fallback exactly as the reference does, so only the Latin runs wear
/// the serif.
struct NewSessionWelcomeView: View {
    let displayName: String?

    @Environment(\.colorScheme) private var colorScheme

    /// Measured 30.3 pt on the 3× capture.
    private let markDiameter: CGFloat = 30
    /// Measured: 50 px CJK ink at 3×, 151.7 pt for the whole line.
    private let greetingSize: CGFloat = 20

    private static let markColor = Color(red: 204 / 255, green: 120 / 255, blue: 92 / 255)

    private var name: String {
        displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var greeting: String {
        let part = Self.timeOfDayGreeting()
        return name.isEmpty ? part : "\(part)，\(name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("aa-AgentClaudeCode")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: markDiameter, height: markDiameter)
                .foregroundStyle(Self.markColor)
                .accessibilityHidden(true)

            Text(greeting)
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.serifFontName,
                                                    size: greetingSize,
                                                    weight: 400)))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)

            planPill
                .padding(.top, 40)
        }
        .frame(maxWidth: .infinity)
    }

    /// The official plan chip. Copy is the capture's; the app has no billing of
    /// its own, so this is presentation only.
    private var planPill: some View {
        HStack(spacing: 4) {
            Text(String(localized: "Free plan"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 12, weight: 400)))
                .foregroundStyle(pillSecondary)
            Text(verbatim: "·")
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 12, weight: 400)))
                .foregroundStyle(pillSecondary)
            Text(String(localized: "Upgrade"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 12, weight: 600)))
                .foregroundStyle(pillPrimary)
        }
        .padding(.horizontal, 17)
        .frame(height: 36)
        .background(Capsule().fill(pillFill))
    }

    // MARK: - Colours

    private var ink: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.88)
            : Color(red: 56 / 255, green: 56 / 255, blue: 53 / 255)
    }

    private var pillFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 240 / 255, green: 239 / 255, blue: 236 / 255)
    }

    private var pillSecondary: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.62)
            : Color(red: 82 / 255, green: 81 / 255, blue: 78 / 255)
    }

    private var pillPrimary: Color {
        colorScheme == .dark ? Color.white : Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255)
    }

    private static func timeOfDayGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "早上好")
        case 12..<18: return String(localized: "下午好")
        default: return String(localized: "晚上好")
        }
    }
}
