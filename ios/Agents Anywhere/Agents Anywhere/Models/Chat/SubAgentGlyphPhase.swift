import Foundation

/// The capsule glyph's two-phase classification (侦察 / 写入) — a display-only
/// projection of what a running SubAgent's recent tool calls look like
/// (ios-subagent-capsule-glyph §2/§3).
///
/// Deliberately unrelated to `SubAgentPhase` (a card's lifecycle phase): this
/// enum only says what a *running* card appears to be doing right now, so the
/// dynamic icon can colour itself. Everything here is a pure function of the
/// tool names already persisted on the timeline — no new state, no timers, no
/// runtime branching (the same name table serves claude CamelCase, dsh
/// lowercase and codex native names after normalisation).
enum SubAgentGlyphPhase: Hashable {
    /// Reading / searching / fetching — the magnifier stage.
    case scouting
    /// Writing / editing files — the pencil stage.
    case writing

    // MARK: - Name table (§2, the single source of truth)

    /// Scouting tool names, lowercased. The runtime's CamelCase names and the
    /// generic lowercase aliases both land here after normalisation.
    private static let scoutingTools: Set<String> = [
        "read", "glob", "grep", "webfetch", "websearch", "notebookread",
        "web_search", "web_fetch", "list", "ls", "cat",
    ]

    /// Writing tool names, lowercased.
    private static let writingTools: Set<String> = [
        "write", "edit", "multiedit", "notebookedit", "str_replace_editor",
        "apply_patch", "create_file",
    ]

    /// One tool name's class, or nil for a neutral/unlisted name.
    ///
    /// §2: everything not listed is nil (宁缺勿假 — never guess). Bash, Agent /
    /// Task / SendMessage, TodoWrite, AskUserQuestion, mcp__* and Cron* are all
    /// deliberately neutral: they neither classify nor break a run. The name is
    /// trimmed and lowercased first, so the test is case-insensitive.
    static func toolClass(_ toolName: String) -> SubAgentGlyphPhase? {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scoutingTools.contains(name) { return .scouting }
        if writingTools.contains(name) { return .writing }
        return nil
    }

    // MARK: - Phase resolution (§3.2, pure)

    /// The phase the glyph shows for a tool history, with 保持 semantics.
    ///
    /// Only a **run of ≥2 consecutive same-class** tool calls holds or flips
    /// the phase; the class of the newest such run wins. The history is read
    /// newest→oldest and neutrals are dropped (a neutral neither joins nor
    /// breaks a run). An uninterrupted alternation — no two adjacent same-class
    /// calls anywhere — has no stable phase, so the result is nil and the glyph
    /// auto-cycles.
    ///
    /// Examples: `["Read"]`→nil; `["Read","Read"]`→scouting;
    /// `["Read","Edit"]`→nil (single flip); `["Read","Read","Edit"]`→scouting
    /// (hold, the Edit is one flip); `["Read","Edit","Edit"]`→writing;
    /// `["Read","Edit","Read","Edit"]`→nil; `["Read","Read","Bash","Read"]`→
    /// scouting (the neutral Bash does not break the run).
    static func resolve(toolHistory: [String]) -> SubAgentGlyphPhase? {
        // The classifiable calls, newest→oldest (neutrals dropped).
        let classes = toolHistory.reversed().compactMap { toolClass($0) }
        guard classes.count >= 2 else { return nil }
        // The newest adjacent same-class pair; its class is the answer.
        for index in 0..<(classes.count - 1) where classes[index] == classes[index + 1] {
            return classes[index]
        }
        return nil
    }

    // MARK: - Live phase for a card (§3.3)

    /// The glyph phase for one running card: the class of its child tool rows
    /// in timeline order. Child rows are the ones the connector attributed with
    /// `content.parentItemId == card.id`; only tool rows carry a tool name, read
    /// from the same keys the presentation uses (`toolName`, then `name`,
    /// `tool`, `title`).
    ///
    /// When no child tool rows are loaded (the card was pushed out of the
    /// window and only its sidecar survives), the card's live tasks'
    /// `lastToolName` is the single-point fallback. A lone name never forms a
    /// run, so this normally returns nil — the glyph auto-cycles instead of
    /// inventing a phase (不得编造).
    static func livePhase(for card: SubAgentCard, in items: [V2TimelineItem]) -> SubAgentGlyphPhase? {
        let toolNames = SubAgentProgress.children(of: card.id, in: items)
            .filter { $0.type == .tool }
            .sorted { $0.orderSeq < $1.orderSeq }
            .compactMap { item -> String? in
                let raw = item.raw["content"] ?? .object([:])
                return TimelineText.first(raw["toolName"], raw["name"], raw["tool"], raw["title"])
            }
        if !toolNames.isEmpty { return resolve(toolHistory: toolNames) }
        return resolve(toolHistory: card.liveTasks.compactMap(\.lastToolName))
    }
}
