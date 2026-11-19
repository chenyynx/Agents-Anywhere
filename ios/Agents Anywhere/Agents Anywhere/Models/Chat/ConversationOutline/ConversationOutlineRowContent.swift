import Foundation

/// The strings the outline rows need. Injected so the row logic stays testable
/// without depending on the process locale.
nonisolated struct ConversationOutlineStrings: Equatable, Sendable {
    var you: String = String(localized: "您")
    /// The session's agent name, not a hardcoded "Claude": AA runs Claude,
    /// Codex and DSH sessions through the same page.
    var agentName: String = "Claude"
    var youSaidFormat: String = String(localized: "您说，%@")
    var agentSaidFormat: String = String(localized: "%1$@ 说，%2$@")
    var emptyMessage: String = String(localized: "（空消息）")
    var replyInProgress: String = String(localized: "（回复进行中）")
    var attachmentsFormat: String = String(localized: "（%lld 个附件）")

    func attachments(_ count: Int) -> String {
        String(format: attachmentsFormat, Int64(count))
    }

    func speaker(for sender: V2MessageRole) -> String {
        sender == .user ? you : agentName
    }

    func spokenTitle(for sender: V2MessageRole, title: String) -> String {
        if sender == .user { return String(format: youSaidFormat, title) }
        return String(format: agentSaidFormat, agentName, title)
    }
}

/// One row's ready-to-render content.
nonisolated struct ConversationOutlineRowContent: Equatable {
    let id: V2TimelineItemID
    /// The exact message a tap opens; nil for the row's first message.
    let partID: V2TimelineItemID?
    /// Whether the row belongs to the human, so the view can pick the avatar.
    let isUser: Bool
    let speaker: String
    /// The title with its inline Markdown resolved (bold/code spans carry
    /// their presentation intent) and the markers removed.
    let titleAttributed: AttributedString
    /// The same title as plain text, for VoiceOver and tests.
    let title: String
    let spokenTitle: String
    let detail: String
    /// `nil` means unlimited (the official's lineLimit 0); 2 is the plain
    /// outline's clamp. SwiftUI's `.lineLimit(nil)` is the unlimited form —
    /// passing 0 renders a single line.
    let titleLineLimit: Int?
}

/// Applies the official row-content precedence:
/// search excerpt → attachment count → reply in progress → empty message.
nonisolated enum ConversationOutlineRowContentMaker {
    static let titleLineLimit = 2

    static func content(
        for entry: ConversationOutlineEntry,
        hit: ConversationOutlineSearchHit?,
        strings: ConversationOutlineStrings = .init(),
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ConversationOutlineRowContent {
        let text = preview(entry.text)
        let attributed: AttributedString
        // Search rows are not clamped to two lines: the official result grows
        // with the whole matched message (the flag that sets `lineLimit = 0`
        // in the capture). The plain outline keeps the two-line preview.
        var lineLimit: Int? = titleLineLimit
        if let hit, !hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The search hit already carries its Markdown-resolved excerpt
            // (and the formatted slice), so it is ready to render as-is.
            attributed = hit.snippetAttributed
            lineLimit = nil
        } else if entry.attachmentCount > 0 {
            attributed = AttributedString(strings.attachments(entry.attachmentCount))
        } else if entry.isArriving {
            attributed = AttributedString(strings.replyInProgress)
        } else if text.isEmpty {
            attributed = AttributedString(strings.emptyMessage)
        } else {
            attributed = markdownTitle(text)
        }
        let title = String(attributed.characters)
        return ConversationOutlineRowContent(
            id: entry.id,
            partID: hit?.partID,
            isUser: entry.sender == .user,
            speaker: strings.speaker(for: entry.sender),
            titleAttributed: attributed,
            title: title,
            spokenTitle: strings.spokenTitle(for: entry.sender, title: title),
            detail: stamp(entry.sentAt, now: now, calendar: calendar, locale: locale),
            titleLineLimit: lineLimit
        )
    }

    /// The official title is an AttributedString: `**bold**` and `` `code` ``
    /// render as such instead of leaking their markers into the row.
    static func markdownTitle(_ value: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: value, options: options))
            ?? AttributedString(value)
    }

    /// The official preview folds every run of whitespace — including the
    /// `\n` that joins a merged row's messages — into one space, so a row
    /// reads as one continuous excerpt instead of stacked paragraphs.
    static func preview(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The official outline keeps month/day for the current year and adds the
    /// year only when it differs from today's. Today keeps the month/day form —
    /// unlike `ChatTimestamp`, which renders only the clock for today.
    static func stamp(
        _ date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date else { return "" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let template = sameYear ? "MMMd HH:mm" : "yMMMd HH:mm"
        let format = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? "MMM d HH:mm"
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
