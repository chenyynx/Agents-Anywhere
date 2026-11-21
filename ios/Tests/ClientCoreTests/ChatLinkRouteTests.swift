import Foundation
import Testing
@testable import ClientCore

/// The Code page's body text and its `OpenURLAction` must agree on what a
/// tapped URL means. These cases pin the routing table: a file reference
/// opens the workspace preview, a system link goes to the system, and
/// everything else is swallowed.
@Suite struct ChatLinkRouteTests {
    @Test func workspaceFileLinkCarriesItsLocation() throws {
        let reference = SessionFileReference(path: "/home/ubuntu/aa-downloads/a.pdf",
                                             line: 12, column: 3)
        let link = try #require(reference.link)
        #expect(ChatLinkRoute.route(link) == .file(reference))
    }

    @Test func explicitPosixPathIsAFileReference() {
        // An inline code path is linked verbatim; the tap must preview it.
        #expect(ChatLinkRoute.route(URL(string: "/home/ubuntu/aa-downloads/a.pdf")!)
            == .file(SessionFileReference(path: "/home/ubuntu/aa-downloads/a.pdf")))
    }

    @Test func externalLinksBelongToTheSystem() {
        #expect(ChatLinkRoute.route(URL(string: "https://example.com/report")!) == .system)
        #expect(ChatLinkRoute.route(URL(string: "http://example.com")!) == .system)
        #expect(ChatLinkRoute.route(URL(string: "mailto:someone@example.com")!) == .system)
        #expect(ChatLinkRoute.route(URL(string: "tel:+123456789")!) == .system)
    }

    @Test func unknownSchemesAreSwallowed() {
        #expect(ChatLinkRoute.route(URL(string: "ftp://example.com/a.pdf")!) == .ignore)
        #expect(ChatLinkRoute.route(URL(string: "javascript:alert(1)")!) == .ignore)
    }
}
