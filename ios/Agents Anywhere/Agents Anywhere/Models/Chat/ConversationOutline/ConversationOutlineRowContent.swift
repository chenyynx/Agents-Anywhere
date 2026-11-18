import Foundation

/// The strings the outline rows need. Injected so the row logic stays testable
/// without depending on the process locale.
nonisolated struct ConversationOutlineStrings: Equatable, Sendable {
    var you: String = String(localized: "您")
    var claude: String = "Claude"
    var youSaidFormat: String = String(localized: "您说，%@")
    var claudeSaidFormat: String = String(localized: "Claude 说，%@")
    var emptyMessage: String = String(localized: "（空消息）")
    var replyInProgress: String = String(localized: "（回复进行中）")
    var attachmentsFormat: String = String(localized: "（%lld 个附件）")

    func attachments(_ count: Int) -> String {
        String(format: attachmentsFormat, Int64(count))
    }

    func speaker(for sender: V2MessageRole) -> String {
        sender == .user ? you : claude
    }

    func spokenTitle(for sender: V2MessageRole, title: String) -> String {
        String(format: sender == .user ? youSaidFormat : claudeSaidFormat, title)
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
    let title: String
    let spokenTitle: String
    let detail: String
    let titleLineLimit: Int
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
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let hit, !hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = hit.snippet
        } else if entry.attachmentCount > 0 {
            title = strings.attachments(entry.attachmentCount)
        } else if entry.isArriving {
            title = strings.replyInProgress
        } else if text.isEmpty {
            title = strings.emptyMessage
        } else {
            title = text
        }
        return ConversationOutlineRowContent(
            id: entry.id,
            partID: hit?.partID,
            isUser: entry.sender == .user,
            speaker: strings.speaker(for: entry.sender),
            title: title,
            spokenTitle: strings.spokenTitle(for: entry.sender, title: title),
            detail: stamp(entry.sentAt, now: now, calendar: calendar, locale: locale),
            titleLineLimit: titleLineLimit
        )
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
