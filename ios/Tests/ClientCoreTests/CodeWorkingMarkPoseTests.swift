import Foundation
import Testing
@testable import ClientCore

// The official working mark's pose is chosen from the live turn's last event,
// not fixed to `think` (`SessionDisplay.liveTurnMark`, predicate 0x10255dcc8).
// These tests pin the tool → pose table read out of the official jump tables
// and the precedence: active thinking > running tool > last tool > think.

@Suite("Code working mark pose")
struct CodeWorkingMarkPoseTests {

    private func row(_ role: V2MessageRole? = .assistant,
                     reasoning: Bool = false,
                     active: Bool = false,
                     tool: String? = nil) -> CodeWorkingMarkRow {
        CodeWorkingMarkRow(role: role, isReasoning: reasoning,
                           isActive: active, toolName: tool)
    }

    // MARK: Tool table

    @Test func bashFamilyUsesTheCodePose() {
        for name in ["Bash", "BashOutput", "Git", "KillShell", "tmux",
                     "shell", "run_command"] {
            #expect(CodeWorkingMarkPose.body(forToolName: name) == .code, "\(name)")
        }
    }

    @Test func writeFamilyUsesTheWritePose() {
        for name in ["Edit", "MultiEdit", "Write", "NotebookEdit",
                     "TodoWrite", "SendMessage", "SendUserMessage",
                     "apply_patch", "create"] {
            #expect(CodeWorkingMarkPose.body(forToolName: name) == .write, "\(name)")
        }
    }

    @Test func readFamilyUsesTheReadPose() {
        for name in ["Read", "Glob", "Grep", "ListMcpResources",
                     "readMcpResource", "NotebookRead", "view"] {
            #expect(CodeWorkingMarkPose.body(forToolName: name) == .read, "\(name)")
        }
    }

    @Test func webFamilyUsesTheSearchPose() {
        for name in ["WebSearch", "web_search", "WebFetch", "web-fetch"] {
            #expect(CodeWorkingMarkPose.body(forToolName: name) == .search, "\(name)")
        }
    }

    @Test func everythingElseIsGeneric() {
        for name in ["Agent", "Task", "Skill", "AskUserQuestion",
                     "ExitPlanMode", "StartTask", "someMcpTool"] {
            #expect(CodeWorkingMarkPose.body(forToolName: name) == .generic, "\(name)")
        }
    }

    // MARK: Live-turn precedence

    @Test func emptyTurnIsThink() {
        #expect(CodeWorkingMarkPose.body(rows: []) == .think)
    }

    @Test func textOnlyTurnIsThink() {
        #expect(CodeWorkingMarkPose.body(rows: [row()]) == .think)
    }

    @Test func runningToolWins() {
        let rows = [row(tool: "Write"),
                    row(active: true, tool: "Read")]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .read)
    }

    @Test func trailingRunningToolWinsAmongSeveral() {
        let rows = [row(active: true, tool: "Read"),
                    row(active: true, tool: "Bash")]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .code)
    }

    @Test func settledTurnKeepsTheLastToolPose() {
        let rows = [row(tool: "WebSearch"),
                    row(tool: "Edit")]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .write)
    }

    @Test func activeThinkingBeatsAnOlderTool() {
        let rows = [row(tool: "Bash"),
                    row(reasoning: true, active: true)]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .think)
    }

    @Test func closedThinkingFallsBackToTheTool() {
        let rows = [row(tool: "Bash"),
                    row(reasoning: true, active: false)]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .code)
    }

    @Test func theLiveTurnStopsAtTheLastUserMessage() {
        let rows = [row(tool: "Bash", active: false),
                    row(.user)]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .think)
    }

    @Test func aRunningToolAfterTheUserMessageStillCounts() {
        let rows = [row(tool: "Bash"),
                    row(.user),
                    row(active: true, tool: "Grep")]
        #expect(CodeWorkingMarkPose.body(rows: rows) == .read)
    }
}
