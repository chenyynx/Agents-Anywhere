import Foundation

/// The official working-mark poses (`WorkingMarkBody`, tag 0–6).
///
/// Lives in the model layer so the pose *choice* is unit-testable without
/// UIKit; `WorkingMarkRenderer` (Views) owns the artwork and the flipbook.
/// Raw values are the official sprite-sheet names (`working-mark/think` …).
nonisolated enum WorkingMarkBody: String, CaseIterable, Sendable {
    case think
    case generic
    case search
    case read
    case code
    case write
    case blocked
}

/// One transcript row reduced to the facts the pose predicate needs.
///
/// A plain value so `CodeWorkingMarkPose.body(rows:)` stays free of the
/// `@MainActor` timeline model and runs in unit tests without a view layer.
nonisolated struct CodeWorkingMarkRow: Equatable, Sendable {
    let role: V2MessageRole?
    let isReasoning: Bool
    let isActive: Bool
    /// The tool's wire name when the row is a tool row; `nil` otherwise.
    let toolName: String?

    init(role: V2MessageRole?, isReasoning: Bool, isActive: Bool, toolName: String?) {
        self.role = role
        self.isReasoning = isReasoning
        self.isActive = isActive
        self.toolName = toolName
    }
}

/// Official tool → pose mapping and live-turn pose choice.
///
/// Source: the official `SessionDisplay.liveTurnMark` predicate `0x10255dcc8`
/// (disassembled 2026-10-25). It flattens the trailing assistant message's
/// `toolCalls` blocks, prefers the trailing-most **running** call, falls back
/// to the trailing-most call when none is running, and returns `think` when a
/// thinking block is still active or the turn has no tool calls. The tag it
/// returns feeds `WorkingMarkBody`; each tool name maps through
/// `ClaudeCodeApi.ToolInput` (declaration order from `swift_types.csv`
/// 38140–38177) with these jump targets read out of the three dispatch tables
/// at `0x1044a5f65`, `0x1044a5f3f` and `0x1044a6122`:
///
/// - `code(4)`: bash, bashOutput, git, killShell, tmux
/// - `write(5)`: fileEdit, fileMultiEdit, fileWrite, hearthSpeech,
///   notebookEdit, sendMessage, sendUserFile, sendUserMessage, todoWrite
/// - `read(3)`: fileRead, glob, grep, listMcpResources, readMcpResource
/// - `search(2)`: webFetch, webSearch
/// - `generic(1)`: every other known tool
/// - `think(0)`: no tool call, or the trailing thinking block is active
///
/// `blocked(6)` is not produced by this predicate in the official binary; it
/// is kept here only because the sprite sheet exists.
nonisolated enum CodeWorkingMarkPose {

    /// The pose for one tool call, matched by its wire name.
    ///
    /// Names are normalised (lowercase, separators removed) because the same
    /// tool reaches the client as `Read`, `read` or `read_file` depending on
    /// the runtime; the official mapping is defined on the Claude Code names
    /// and the aliases below are AA's existing classifier vocabulary.
    static func body(forToolName name: String) -> WorkingMarkBody {
        switch normalize(name) {
        case "bash", "bashoutput", "git", "killshell", "tmux",
             "shell", "runcommand", "command":
            return .code
        case "edit", "fileedit", "multiedit", "filemultiedit",
             "write", "filewrite", "create",
             "notebookedit", "applypatch", "patch",
             "todowrite", "updateplan",
             "sendmessage", "senduserfile", "sendusermessage",
             "hearthspeech":
            return .write
        case "read", "fileread", "notebookread", "view",
             "glob", "grep",
             "listmcpresources", "readmcpresource":
            return .read
        case "websearch", "webfetch":
            return .search
        default:
            return .generic
        }
    }

    /// The live turn's pose, from the transcript rows in display order.
    ///
    /// Walks back to the last user message (the live turn), then applies the
    /// official precedence: an active thinking block wins, then the
    /// trailing-most running tool, then the trailing-most tool, then `think`.
    /// Text blocks do not affect the pose — the official predicate only looks
    /// at `thinking` and `toolCalls` blocks.
    static func body(rows: [CodeWorkingMarkRow]) -> WorkingMarkBody {
        var lastThinkingActive = false
        var sawThinking = false
        var runningToolName: String?
        var lastToolName: String?

        for row in rows.reversed() {
            if row.role == .user { break }
            if row.isReasoning {
                // Only the trailing-most thinking block decides; the older
                // ones are closed by definition.
                if !sawThinking {
                    sawThinking = true
                    lastThinkingActive = row.isActive
                }
                continue
            }
            guard let toolName = row.toolName else { continue }
            if lastToolName == nil { lastToolName = toolName }
            if runningToolName == nil, row.isActive { runningToolName = toolName }
        }

        if lastThinkingActive { return .think }
        if let runningToolName { return body(forToolName: runningToolName) }
        if let lastToolName { return body(forToolName: lastToolName) }
        return .think
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
