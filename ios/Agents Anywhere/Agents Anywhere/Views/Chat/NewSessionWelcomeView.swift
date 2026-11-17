import SwiftUI

/// The new-session empty state, matched to the official Claude chat page
/// (pp 2026-11-17): the runtime's mark, a time-of-day greeting carrying the
/// account's display name, and a pill carrying the working directory.
///
/// The mark follows the runtime (pp 2026-11-17) — same mapping as the sidebar,
/// with Claude in its clay and DeepSeek in its blue; Codex and the bot mark
/// stay monochrome. Measurements are off the 3× capture: mark 30 pt, greeting
/// 19 pt in Anthropic Serif (#383835), pill 36 pt tall on #F0EFEC with an 11 pt
/// label (regular #52514E, "Upgrade" semibold #0B0B0B). The Chinese resolves to
/// the system fallback exactly as the reference does, so only the Latin runs
/// wear the serif.
struct NewSessionWelcomeView: View {
    let displayName: String?
    let runtime: V2DeviceRuntime?
    let workspaceName: String
    let onChooseWorkspace: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Measured 30.3 pt on the 3× capture.
    private let markDiameter: CGFloat = 30
    /// Official ink is 50 px at 3×; ours measured 52 px at 20 pt, so 19.
    private let greetingSize: CGFloat = 19

    private var mark: (asset: String, label: String) {
        SessionAgentMark.resolve(runtime: runtime?.runtimeType ?? "",
                                 runtimeType: runtime?.runtimeType)
    }

    private var markTint: Color {
        SessionAgentMark.tint(runtime: runtime?.runtimeType ?? "",
                              runtimeType: runtime?.runtimeType) ?? .primary
    }

    private var name: String {
        displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var greeting: String {
        let part = Self.timeOfDayGreeting()
        return name.isEmpty ? part : "\(part)，\(name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(mark.asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: markDiameter, height: markDiameter)
                .foregroundStyle(markTint)
                .accessibilityHidden(true)

            Text(greeting)
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.serifFontName,
                                                    size: greetingSize,
                                                    weight: 400)))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)

            Button(action: onChooseWorkspace) {
                workspacePill
            }
            .buttonStyle(.plain)
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity)
    }

    /// The official pill, carrying what the official one would not: the working
    /// directory this session will start in — and the way to change it. Two
    /// weights like the capture: a secondary label and the name in ink.
    private var workspacePill: some View {
        HStack(spacing: 4) {
            Text(String(localized: "工作目录"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 11, weight: 400)))
                .foregroundStyle(pillSecondary)
            Text(verbatim: "·")
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 11, weight: 400)))
                .foregroundStyle(pillSecondary)
            Text(workspaceName)
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 11, weight: 600)))
                .foregroundStyle(pillPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 17)
        .frame(height: 36)
        .background(Capsule().fill(pillFill))
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
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
