import Foundation
import Testing
@testable import ClientCore

/// The runtime context-usage wire model (`ProtocolContextUsage`): full claude
/// answers carry the breakdown; codex answers are summary-only.
@Suite struct ContextUsageReportTests {
    private func decode(_ usage: String) throws -> V2ContextUsage {
        let json = """
        {"usage": \(usage), "serverTime": "2026-11-12T00:00:00Z"}
        """
        return try JSONDecoder()
            .decode(V2ContextUsageResponse.self, from: Data(json.utf8))
            .usage
    }

    @Test func decodesFullBreakdown() throws {
        let usage = try decode("""
        {
          "runtime": "claude",
          "totalTokens": 84200,
          "model": "claude-opus-5-5",
          "maxTokens": 200000,
          "percentage": 42,
          "detail": "full",
          "source": "claude.control",
          "measuredAt": "2026-11-12T00:00:00Z",
          "categories": [
            {"name": "System prompt", "tokens": 1200, "kind": "used"},
            {"name": "Free space", "tokens": 9000, "kind": "free"}
          ],
          "mcpTools": [
            {"name": "create_issue", "serverName": "linear", "tokens": 300}
          ],
          "memoryFiles": [
            {"path": "/repo/CLAUDE.md", "tokens": 800, "type": "Project"}
          ],
          "agents": [
            {"agentType": "reviewer", "tokens": 120, "source": "userSettings"}
          ],
          "skills": [
            {"name": "commit", "tokens": 40, "source": "projectSettings"}
          ]
        }
        """)

        #expect(usage.runtime == "claude")
        #expect(usage.model == "claude-opus-5-5")
        #expect(usage.percentUsed == 42)
        #expect(usage.remainingPercent == 58)
        #expect(usage.hasBreakdown)
        #expect(usage.categories.count == 2)
        #expect(usage.visibleCategories.count == 2)
        #expect(usage.categories[1].isFreeOrBuffer)
        #expect(usage.mcpTools.first?.serverName == "linear")
        #expect(usage.memoryFiles.first?.path == "/repo/CLAUDE.md")
        #expect(usage.agents.first?.agentType == "reviewer")
        #expect(usage.skills.first?.name == "commit")
        #expect(usage.measuredAt == "2026-11-12T00:00:00Z")
        // 84,200 / 200,000 = 0.421.
        #expect(abs((usage.fraction ?? 0) - 0.421) < 0.0001)
    }

    @Test func decodesSummaryOnlyRuntime() throws {
        let usage = try decode("""
        {
          "runtime": "codex",
          "totalTokens": 84000,
          "model": "gpt-5",
          "maxTokens": 200000,
          "percentage": 42,
          "detail": "summary",
          "source": "codex.event"
        }
        """)

        #expect(!usage.hasBreakdown)
        #expect(usage.categories.isEmpty)
        #expect(usage.mcpTools.isEmpty)
        #expect(usage.memoryFiles.isEmpty)
        #expect(usage.agents.isEmpty)
        #expect(usage.skills.isEmpty)
        #expect(usage.percentUsed == 42)
    }

    @Test func derivesPercentWhenRuntimeOmitsIt() throws {
        let usage = try decode("""
        {"runtime": "claude", "totalTokens": 50000, "maxTokens": 200000}
        """)

        #expect(usage.percentUsed == 25)
        #expect(usage.remainingPercent == 75)
    }

    @Test func missingWindowOrUsageStaysUnknownRatherThanZero() throws {
        let usage = try decode("""
        {"runtime": "claude", "totalTokens": 1200}
        """)

        #expect(usage.fraction == nil)
        #expect(usage.percentUsed == nil)
        #expect(usage.remainingPercent == nil)
    }

    @Test func zeroTokenCategoriesAreHidden() throws {
        let usage = try decode("""
        {
          "runtime": "claude",
          "totalTokens": 10,
          "maxTokens": 100,
          "categories": [
            {"name": "Used", "tokens": 10, "kind": "used"},
            {"name": "Empty", "tokens": 0, "kind": "used"}
          ]
        }
        """)

        #expect(usage.categories.count == 2)
        #expect(usage.visibleCategories.map(\.name) == ["Used"])
    }

    @Test func fractionClampsAtOne() throws {
        let usage = try decode("""
        {"runtime": "claude", "totalTokens": 250000, "maxTokens": 200000}
        """)

        #expect(usage.fraction == 1)
    }

    @Test func percentIsClampedToTheWindow() throws {
        let over = try decode("""
        {"runtime": "claude", "totalTokens": 250000, "maxTokens": 200000,
         "percentage": 250}
        """)
        #expect(over.percentUsed == 100)
        #expect(over.remainingPercent == 0)

        let under = try decode("""
        {"runtime": "claude", "totalTokens": 0, "maxTokens": 200000,
         "percentage": -5}
        """)
        #expect(under.percentUsed == 0)
        #expect(under.remainingPercent == 100)
    }

    @Test func tokenFormattingMatchesTheOfficialSheet() {
        #expect(ContextTokenFormat.wan(0) == "0")
        #expect(ContextTokenFormat.wan(999) == "999")
        #expect(ContextTokenFormat.wan(1000) == "0.1万")
        #expect(ContextTokenFormat.wan(9999) == "1万")
        #expect(ContextTokenFormat.wan(10000) == "1万")
        #expect(ContextTokenFormat.wan(16000) == "1.6万")
        #expect(ContextTokenFormat.wan(105000) == "10.5万")
        #expect(ContextTokenFormat.wan(260000) == "26万")
    }
}

/// Client plumbing: the API carries `detail` on the query and decodes the
/// response; the model never asks without a usable capability.
@Suite @MainActor struct ContextUsageClientTests {
    @Test func apiSendsDetailAndDecodesResponse() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            #expect(call.path.hasSuffix("/runtime/context-usage"))
            #expect(call.query.contains(URLQueryItem(name: "detail", value: "full")))
            return Data("""
            {
              "usage": {
                "runtime": "claude",
                "totalTokens": 1234,
                "maxTokens": 200000,
                "percentage": 1,
                "detail": "full",
                "source": "claude.control"
              },
              "serverTime": "2026-11-12T00:00:00Z"
            }
            """.utf8)
        }
        let api = V2RuntimeAPI(transport: http)
        let response = try await api.contextUsage(sessionId: "session", detail: .full)
        #expect(response.usage.totalTokens == 1234)
        #expect(response.usage.percentUsed == 1)
    }

    @Test func modelSkipsTheReadWithoutTheCapability() async {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        let chat = SessionChatModel(
            session: repo.session(id: "session"),
            repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http))
        )

        await chat.refreshContextUsage(sessionID: "session")

        #expect(chat.contextUsage == nil)
        #expect(http.count("context-usage") == 0)
    }
}
