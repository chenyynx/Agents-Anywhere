import Foundation
import Testing
@testable import ClientCore

/// Recognition rules for the three message entries (plan §3.3b): a path becomes
/// clickable only when it is an absolute path or a real workspace file. The
/// negative samples below are the误伤 guard — ordinary prose, URLs, e-mail
/// addresses, versions, fractions and directory names must all stay plain text.
@Suite @MainActor struct WorkspaceFileRecognitionTests {
    /// `src/` is a directory (dropped from the suffix set), so `src` must never
    /// match; `lib/main.dart` is a real file.
    private let catalog = WorkspaceFileCatalog(files: ["lib/main.dart", "src/", "docs/", "README.md"])

    // MARK: - Entry ①: backtick-quoted code

    @Test func backtickCatalogMemberBecomesAReference() {
        #expect(FileReferenceScanner.codeReference("main.dart", catalog: catalog) == "main.dart")
        #expect(FileReferenceScanner.codeReference("lib/main.dart", catalog: catalog) == "lib/main.dart")
        #expect(FileReferenceScanner.codeReference("README.md", catalog: catalog) == "README.md")
    }

    @Test func backtickReferenceStripsLineColumnBeforeMatching() {
        // `:line:col` is stripped, so the member "main.dart" still matches and
        // the returned path carries no suffix.
        #expect(FileReferenceScanner.codeReference("main.dart:42", catalog: catalog) == "main.dart")
        #expect(FileReferenceScanner.codeReference("lib/main.dart:42:8", catalog: catalog) == "lib/main.dart")
    }

    @Test func backtickNonPathStaysPlainCode() {
        for content in ["git status", "npm run build", "请打开文件", "42", "3/4", "1.2.3"] {
            #expect(FileReferenceScanner.codeReference(content, catalog: catalog) == nil, "\(content) must stay code")
        }
    }

    @Test func backtickDirectoryNameStaysPlainCode() {
        // A directory entry (trailing slash) contributes no suffix: it is not a file.
        #expect(FileReferenceScanner.codeReference("src", catalog: catalog) == nil)
        #expect(FileReferenceScanner.codeReference("docs", catalog: catalog) == nil)
    }

    @Test func backtickAbsolutePathIsAlwaysRecognized() {
        // Not in the (possibly truncated) catalog, but a full path → recognized.
        #expect(FileReferenceScanner.codeReference("/home/x/y.md", catalog: catalog) == "/home/x/y.md")
    }

    // MARK: - Entry ②: bare text tokens

    @Test func bareCatalogNameBecomesALink() {
        let text = "please open main.dart now"
        let ranges = FileReferenceScanner.bareReferences(in: text, catalog: catalog)
        #expect(ranges.map { String(text[$0]) } == ["main.dart"])
    }

    @Test func bareRelativePathBecomesALink() {
        let text = "see lib/main.dart for details"
        #expect(FileReferenceScanner.bareReferences(in: text, catalog: catalog).map { String(text[$0]) } == ["lib/main.dart"])
    }

    @Test func bareTokenStopsAtTrailingPunctuation() {
        let text = "the entry point is main.dart."
        #expect(FileReferenceScanner.bareReferences(in: text, catalog: catalog).map { String(text[$0]) } == ["main.dart"])
    }

    @Test func bareDirectoryNameStaysPlain() {
        // "src" has no extension → the bare pattern never matches it, and it is
        // a directory anyway.
        #expect(FileReferenceScanner.bareReferences(in: "the src folder", catalog: catalog).isEmpty)
    }

    /// The误伤 guard: none of these tokens may turn into a link, because none is
    /// a member of the catalog. A dot-regex alone would match the first four.
    @Test func negativeSamplesNeverBecomeBareLinks() {
        let samples = [
            "https://a.com/b.md",
            "reach me at a@b.com",
            "we shipped version 1.2.3 today",
            "the fraction 3/4 stays put",
            "请打开文件",
            "the answer is 42",
            "a plain sentence.",
            "dot.terminated.",
        ]
        for sample in samples {
            #expect(FileReferenceScanner.bareReferences(in: sample, catalog: catalog).isEmpty, "\(sample) must stay plain")
        }
    }

    @Test func bareScanFindsMultipleDistinctMembers() {
        let text = "compare main.dart with README.md"
        #expect(FileReferenceScanner.bareReferences(in: text, catalog: catalog).map { String(text[$0]) } == ["main.dart", "README.md"])
    }

    // MARK: - Absolute-path and directory helpers

    @Test func absolutePathDetectionCoversPosixWindowsAndUNC() {
        #expect(SessionFileReference.isAbsolutePath("/home/x/y.md"))
        #expect(SessionFileReference.isAbsolutePath(#"C:\work\a.md"#))
        #expect(SessionFileReference.isAbsolutePath(#"\\host\share\a.md"#))
        #expect(!SessionFileReference.isAbsolutePath("main.dart"))
        #expect(!SessionFileReference.isAbsolutePath("./main.dart"))
        #expect(!SessionFileReference.isAbsolutePath("../main.dart"))
    }

    @Test func stripLineColumnOnlyDropsATrailingLocation() {
        #expect(SessionFileReference.stripLineColumn("main.dart:42") == "main.dart")
        #expect(SessionFileReference.stripLineColumn("main.dart:42:8") == "main.dart")
        #expect(SessionFileReference.stripLineColumn("main.dart") == "main.dart")
        #expect(SessionFileReference.stripLineColumn("1.2.3") == "1.2.3")
    }

    @Test func recognizeIsAbsoluteOrCatalogMember() {
        // Absolute wins even outside the catalog.
        #expect(SessionFileReference.recognize("/home/x/y.md", catalog: catalog))
        // A catalog member is recognized.
        #expect(SessionFileReference.recognize("main.dart", catalog: catalog))
        #expect(SessionFileReference.recognize("lib/main.dart:42", catalog: catalog))
        // A directory name and an unknown name are not.
        #expect(!SessionFileReference.recognize("src", catalog: catalog))
        #expect(!SessionFileReference.recognize("nope.md", catalog: catalog))
        // A bare name against an as-yet-unloaded (empty) catalog is not.
        #expect(!SessionFileReference.recognize("main.dart", catalog: WorkspaceFileCatalog(files: [])))
    }
}
