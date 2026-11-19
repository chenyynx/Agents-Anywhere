import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline row content")
struct ConversationOutlineRowContentTests {
    private let strings = ConversationOutlineStrings(
        you: "You",
        agentName: "Claude",
        youSaidFormat: "You said, %@",
        agentSaidFormat: "%1$@ said, %2$@",
        emptyMessage: "(Empty message)",
        replyInProgress: "(Reply in progress)",
        attachmentsFormat: "(%lld attachments)"
    )

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private let locale = Locale(identifier: "zh_Hans_CN")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func entry(
        id: String = "e1",
        sender: V2MessageRole = .assistant,
        text: String = "",
        isArriving: Bool = false,
        sentAt: Date? = nil,
        attachmentCount: Int = 0
    ) -> ConversationOutlineEntry {
        ConversationOutlineEntry(
            id: id,
            sender: sender,
            text: text,
            parts: [ConversationOutlineEntry.Part(id: id + "-part", text: text, createdAt: sentAt, isActive: isArriving)],
            isArriving: isArriving,
            sentAt: sentAt,
            attachmentCount: attachmentCount
        )
    }

    @Test("plain text is the title when nothing else applies")
    func plainText() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "hello"), hit: nil, strings: strings
        )
        #expect(content.title == "hello")
        #expect(String(content.titleAttributed.characters) == "hello")
        #expect(content.partID == nil)
        #expect(content.titleLineLimit == 2)
    }

    @Test("markdown markers become attributes instead of leaking into the title")
    func markdownTitleIsAttributed() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "第一轮 **失败原因**(2 处)，都在 `ConversationOutline`"),
            hit: nil, strings: strings
        )
        #expect(content.title == "第一轮 失败原因(2 处)，都在 ConversationOutline")
        #expect(!content.title.contains("**"))
        #expect(!content.title.contains("`"))
        #expect(content.spokenTitle == "Claude said, 第一轮 失败原因(2 处)，都在 ConversationOutline")
        let hasStrong = content.titleAttributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(hasStrong)
    }

    @Test("a search excerpt carries the hit's Markdown-resolved attributed slice")
    func searchExcerptUsesAttributedSnippet() {
        var attributed = AttributedString("…needle…")
        attributed[attributed.startIndex..<attributed.endIndex].inlinePresentationIntent =
            .stronglyEmphasized
        let hit = ConversationOutlineSearchHit(entryID: "e1", partID: "p9",
                                               snippet: "…needle…",
                                               snippetAttributed: attributed,
                                               highlightRanges: [1..<7])
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "body"), hit: hit, strings: strings
        )
        #expect(content.title == "…needle…")
        #expect(String(content.titleAttributed.characters) == "…needle…")
        #expect(content.partID == "p9")
        #expect(content.titleLineLimit == nil)
        #expect(content.highlightRanges == [1..<7])
        let hasStrong = content.titleAttributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(hasStrong)
    }

    @Test("attachments take precedence when the message has no text")
    func attachmentsPlaceholder() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "", attachmentCount: 2), hit: nil, strings: strings
        )
        #expect(content.title == "(2 attachments)")
    }

    @Test("an arriving empty message shows the reply-in-progress placeholder")
    func replyInProgressPlaceholder() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "", isArriving: true), hit: nil, strings: strings
        )
        #expect(content.title == "(Reply in progress)")
    }

    @Test("an empty settled message shows the empty placeholder")
    func emptyPlaceholder() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "   "), hit: nil, strings: strings
        )
        #expect(content.title == "(Empty message)")
    }

    @Test("the speaker uses the session's agent name, not a hardcoded Claude")
    func agentNameIsInjectable() {
        let codexStrings = ConversationOutlineStrings(
            you: "You", agentName: "Codex",
            youSaidFormat: "You said, %@",
            agentSaidFormat: "%1$@ said, %2$@",
            emptyMessage: "(Empty message)",
            replyInProgress: "(Reply in progress)",
            attachmentsFormat: "(%lld attachments)"
        )
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "hi"), hit: nil, strings: codexStrings
        )
        #expect(content.speaker == "Codex")
        #expect(content.spokenTitle == "Codex said, hi")
    }

    @Test("speaker and the spoken title follow the sender")
    func speakerAndSpokenTitle() {
        let user = ConversationOutlineRowContentMaker.content(
            for: entry(sender: .user, text: "hi"), hit: nil, strings: strings
        )
        #expect(user.speaker == "You")
        #expect(user.spokenTitle == "You said, hi")

        let assistant = ConversationOutlineRowContentMaker.content(
            for: entry(sender: .assistant, text: "hello"), hit: nil, strings: strings
        )
        #expect(assistant.speaker == "Claude")
        #expect(assistant.spokenTitle == "Claude said, hello")
    }

    @Test("the preview folds newlines and repeated whitespace into one space")
    func previewNormalizesWhitespace() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "first\nsecond  third\tfourth"), hit: nil, strings: strings
        )
        #expect(content.title == "first second third fourth")
    }

    @Test("the detail uses month and day within the current year")
    func stampSameYear() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "x", sentAt: date(2026, 11, 12, 4, 4)),
            hit: nil,
            strings: strings,
            now: date(2026, 11, 18, 12, 0),
            calendar: calendar,
            locale: locale
        )
        #expect(content.detail == "11月12日 04:04")
    }

    @Test("the detail adds the year when it differs from today")
    func stampDifferentYear() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "x", sentAt: date(2025, 11, 12, 4, 4)),
            hit: nil,
            strings: strings,
            now: date(2026, 11, 18, 12, 0),
            calendar: calendar,
            locale: locale
        )
        #expect(content.detail.contains("2025"))
        #expect(content.detail.contains("11月12日"))
        #expect(content.detail.contains("04:04"))
    }

    @Test("a missing date renders an empty detail")
    func stampMissing() {
        let content = ConversationOutlineRowContentMaker.content(
            for: entry(text: "x", sentAt: nil), hit: nil, strings: strings
        )
        #expect(content.detail.isEmpty)
    }
}
