import SwiftUI

/// Mirrors Web's SessionAgentIcon: the session's agent mark, or Lucide Bot for
/// runtimes without one. Paths come from the same SVGs as the Web sidebar.
struct SessionAgentIcon: View {
    let runtime: String
    let runtimeType: String?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    var body: some View {
        let agent = SessionAgentMark.resolve(runtime: runtime, runtimeType: runtimeType)
        Image(agent.asset).resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(Text(verbatim: agent.label))
    }
}

/// Which mark a runtime wears. Shared by the sidebar and the new-session empty
/// state so the two can never disagree about who the session is talking to.
enum SessionAgentMark {
    static func resolve(runtime: String, runtimeType: String?) -> (asset: String, label: String) {
        switch normalized(runtime: runtime, runtimeType: runtimeType) {
        case "codex": return ("aa-AgentCodex", "Codex")
        case "claude", "claudecode": return ("aa-AgentClaudeCode", "Claude Code")
        case "dsh", "deepseek", "deepseekharness": return ("aa-AgentDeepSeek", "DeepSeekRuntime")
        default: return ("aa-Bot", runtime)
        }
    }

    /// The mark's brand colour, where the brand has one that reads on both
    /// schemes. `nil` means "use the label colour" — Codex and the bot stay
    /// monochrome, which is the right reading for both.
    ///
    /// Claude's value is the capture's, converted from its Display P3 profile
    /// to sRGB: the raw screenshot pixels read (204, 124, 94), which is
    /// (217, 119, 87) — `#D97757` — once the profile is applied.
    static func tint(runtime: String, runtimeType: String?) -> Color? {
        switch normalized(runtime: runtime, runtimeType: runtimeType) {
        case "claude", "claudecode":
            return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case "dsh", "deepseek", "deepseekharness":
            return Color(red: 77 / 255, green: 107 / 255, blue: 254 / 255)
        default:
            return nil
        }
    }

    private static func normalized(runtime: String, runtimeType: String?) -> String {
        let source = runtimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((source?.isEmpty == false ? source! : runtime).lowercased()
            .filter { !$0.isWhitespace && $0 != "_" && $0 != "-" })
    }
}
