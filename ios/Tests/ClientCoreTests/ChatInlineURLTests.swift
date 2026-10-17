import Foundation
import Testing
@testable import ClientCore

@Suite("Inline code URL recognition")
struct ChatInlineURLTests {
    @Test("a scheme-qualified URL matches as written")
    func explicitScheme() throws {
        let url = try #require(ChatInlineURL.url(for: "https://www.google.com/generate_204"))
        #expect(url.absoluteString == "https://www.google.com/generate_204")
    }

    @Test("a bare host with a known suffix gains https")
    func bareHost() throws {
        let url = try #require(ChatInlineURL.url(for: "workbuddy.pipicore.cn"))
        #expect(url.absoluteString == "https://workbuddy.pipicore.cn")
    }

    @Test("a host with a port and path matches")
    func hostWithPort() throws {
        let url = try #require(ChatInlineURL.url(for: "example.com:8443/v1"))
        #expect(url.absoluteString == "https://example.com:8443/v1")
    }

    @Test("file names stay code, not links")
    func fileNames() {
        #expect(ChatInlineURL.url(for: "config.toml") == nil)
        #expect(ChatInlineURL.url(for: "app.py") == nil)
        #expect(ChatInlineURL.url(for: "README.md") == nil)
    }

    @Test("a bare IP with a port stays code")
    func bareAddress() {
        #expect(ChatInlineURL.url(for: "100.79.4.30:18765") == nil)
    }

    @Test("commands and sentences stay code")
    func commands() {
        #expect(ChatInlineURL.url(for: "git status") == nil)
        #expect(ChatInlineURL.url(for: "/etc/systemd/system/sbx-heartbeat.timer") == nil)
    }

    @Test("an unknown top-level domain stays code")
    func unknownSuffix() {
        #expect(ChatInlineURL.url(for: "internal.corp") == nil)
    }
}
