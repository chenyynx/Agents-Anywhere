import Foundation
import Testing
@testable import ClientCore

/// The renderer underlines a web link and leaves a workspace file reference as
/// plain code, so this split decides whether a path reads like a URL.
@Suite("Chat link classification")
struct ChatLinkTests {
    @Test("http and https are web links, whatever the case")
    func webSchemes() throws {
        #expect(ChatLink.isWeb(try #require(URL(string: "https://github.com/morluto/rea"))))
        #expect(ChatLink.isWeb(try #require(URL(string: "http://example.com"))))
        #expect(ChatLink.isWeb(try #require(URL(string: "HTTPS://Example.COM/x"))))
    }

    @Test("a workspace file reference is an in-app jump, not a web link")
    func workspaceReferenceIsNotWeb() throws {
        let link = try #require(SessionFileReference(path: "/data/rea").link)
        #expect(link.scheme?.lowercased() == "aa-workspace-file")
        #expect(!ChatLink.isWeb(link))
    }

    @Test("other schemes are not web links")
    func otherSchemes() throws {
        #expect(!ChatLink.isWeb(try #require(URL(string: "mailto:someone@example.com"))))
        #expect(!ChatLink.isWeb(try #require(URL(string: "file:///tmp/x"))))
        #expect(!ChatLink.isWeb(try #require(URL(string: "aa-workspace-file://preview?path=/a"))))
    }

    @Test("a scheme-less link is not a web link")
    func schemeLess() throws {
        #expect(!ChatLink.isWeb(try #require(URL(string: "//example.com/x"))))
    }
}
