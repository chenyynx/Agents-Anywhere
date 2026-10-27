import Foundation

// The Code page's row model: one assistant message is one row, and the
// message's body, reasoning and tool calls are blocks inside it.
//
// The official page gets this from the server (`DisplayMessage.blocks`). AA's
// wire is row-shaped, but it declares the same grouping truth: a tool row
// carries its enclosing message id in `source.nativeMessageId`, a body or
// reasoning row carries it as `source.itemId`
// (server/agent_server/core/timeline.py `timeline_message_group_key`), and the
// server repacks a group in RBT order — reasoning, then body, then tools by
// `source.blockIndex` (server/agent_server/infra/repositories/timeline.py,
// `_intra_message_target_rows`; v2_43). The builder below applies the same key
// and order on the client, so the row model is derived from declared truth
// rather than arrival time.

nonisolated struct CodeMessageRow: Identifiable, Hashable {
    nonisolated enum Block: Hashable {
        /// The official `Block.thinkingContent`, rendered as the collapsed
        /// `思考过程` row. `status` gates the row: a running thinking block is
        /// the turn-level working line's job, not a transcript row.
        case reasoning(id: String, text: String, status: V2TimelineItemStatus)
        /// `Block.text`.
        case text(id: String, text: String)
        /// The user message's attachments (wire `V2MessageContent.attachments`).
        /// The official page draws them outside the text bubble, as an image
        /// grid and a file row (CLOSURE.md §4), so they are a sibling block of
        /// `.text` rather than part of the bubble. `clientMessageID` is the
        /// send correlation id, kept for the local preview cache.
        case attachments(id: String, files: [V2AttachmentContent], clientMessageID: String?)
        /// `Block.toolCalls`, already segmented.
        case toolCalls([CodeToolSegment])
        /// A row the Code page has no dedicated block for; kept so nothing is
        /// dropped silently, rendered as the page's generic row.
        case other(id: String, type: String)
    }

    let id: String
    /// The role of the row's first message item; a row with no message item
    /// (tool-only, marker, artifact) carries `.system`. The page uses this to
    /// tell a user row from an assistant row.
    let role: V2MessageRole
    let blocks: [Block]
}

nonisolated enum CodeMessageBuilder {
    /// A row's address while building: a message group by its declared key, or
    /// a single row by its item id.
    ///
    /// The two cases are separate namespace entries, so a message key equal to
    /// a standalone item id still gets its own index entry rather than
    /// displacing the other row. Output ids stay as declared (`<message key>`
    /// and `item:<item id>`).
    private enum Slot: Hashable {
        case message(String)
        case item(String)
    }

    /// The enclosing assistant message id: `nativeMessageId` for a tool row,
    /// `itemId` for a body/reasoning row (server `timeline_message_group_key`).
    /// An empty string is absent, exactly as the server's `or` treats it.
    static func groupKey(for item: V2TimelineItem) -> String? {
        TimelineText.first(item.source["nativeMessageId"], item.source["itemId"])
    }

    /// Timeline rows → Code rows, preserving first-seen group order.
    ///
    /// `profile` supplies the runtime's segment policy and its observed
    /// name/kind table; the builder itself never switches on a runtime id.
    ///
    /// Rows that declare no group key, and row types the Code page does not
    /// stack into a message, become their own row. Sub-agent child rows are
    /// left out of the main timeline exactly as the current grouping does
    /// (L2.1): their content belongs to the sub-agent panel.
    static func rows(for items: [V2TimelineItem],
                     profile: CodeRuntimeProfile) -> [CodeMessageRow] {
        var order: [Slot] = []
        var seen: Set<Slot> = []
        var consumed: Set<String> = []
        var grouped: [String: [V2TimelineItem]] = [:]
        var standalone: [String: V2TimelineItem] = [:]

        for item in items {
            if isSubAgentChild(item) { continue }
            // The projection hands over one version per item id. A repeated id
            // inside one call would duplicate a block or a tool segment, so
            // the first occurrence wins and keeps the projection's order.
            guard consumed.insert(item.id).inserted else { continue }
            if isStackable(item), let key = groupKey(for: item) {
                let slot = Slot.message(key)
                if seen.insert(slot).inserted { order.append(slot) }
                grouped[key, default: []].append(item)
            } else {
                let slot = Slot.item(item.id)
                if seen.insert(slot).inserted { order.append(slot) }
                standalone[item.id] = item
            }
        }

        return order.compactMap { slot -> CodeMessageRow? in
            switch slot {
            case let .message(key):
                guard let items = grouped[key] else { return nil }
                return messageRow(id: key, items: items, profile: profile)
            case let .item(id):
                guard let item = standalone[id] else { return nil }
                return CodeMessageRow(id: "item:\(id)",
                                      role: .system,
                                      blocks: [.other(id: id, type: item.type.rawValue)])
            }
        }
    }

    private static func messageRow(id: String, items: [V2TimelineItem],
                                   profile: CodeRuntimeProfile) -> CodeMessageRow? {
        let reasoning = items.filter(isReasoning).sorted(by: wireOrder)
        let bodies = items.filter { !isReasoning($0) && $0.type == .message }.sorted(by: wireOrder)
        let toolRows = orderedToolRows(items.filter(isToolRow))
        let calls = toolRows.map { item in
            CodeToolCall(item: item,
                         kind: profile.kind(for: CodeToolCall.wireName(for: item),
                                            wireKind: CodeToolCall.wireKind(for: item)))
        }
        let segments = CodeToolSegmenter.segments(calls, policy: profile.segmentPolicy)

        var blocks: [CodeMessageRow.Block] = []
        // One message group is one official `DisplayMessage`. Inside it the
        // engine merges consecutive thinking runs into one `thinkingContent`
        // block, skipping tool calls and joining the texts with a blank line
        // (`0x1027365f0`; round24 `tag4-merge-text.md`). AA persists one
        // reasoning row per streamed block, so the same merge happens here.
        // Text between two runs would break the run in the official engine;
        // the server's RBT order already places body rows after all reasoning
        // rows, so this client cannot see that interleaving and merges the
        // group's reasoning rows in wire order instead.
        let reasoningText = reasoning
            .map(\.displayText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if !reasoningText.isEmpty, let first = reasoning.first {
            let settled = reasoning.allSatisfy { $0.status == .done }
            blocks.append(.reasoning(id: first.id,
                                     text: reasoningText,
                                     status: settled ? .done : .running))
        }
        // The official user row draws its attachments first, then the text
        // bubble below them (device screenshots 2026-10-27; the earlier
        // round25 CSV reading of "text then attachments" was the type-tree
        // order, not the rendered block order). A body with no text still
        // keeps its attachments (no bubble for a pure-attachment message),
        // and one file draws once even when several bodies carry it: the key
        // is the server file id, or the payload identity before upload.
        let rowRole = role(of: items)
        // Attachments are a user-message block only; an assistant message's
        // `attachments` payload is not a user grid and must not be drawn with
        // the user attachment layout.
        var seenAttachments: Set<String> = []
        for body in bodies {
            guard rowRole == .user,
                  case let .message(content) = body.content else {
                blocks.append(.text(id: body.id, text: body.displayText))
                continue
            }
            let files = content.attachments.filter { file in
                seenAttachments.insert(attachmentKey(file)).inserted
            }
            if !files.isEmpty {
                blocks.append(.attachments(
                    id: body.id, files: files,
                    clientMessageID: TimelineText.first(body.source["clientMessageId"])))
            }
            blocks.append(.text(id: body.id, text: body.displayText))
        }
        if !segments.isEmpty { blocks.append(.toolCalls(segments)) }
        // A message whose only content is skipped tool calls (ExitPlanMode /
        // AskUserQuestion) has nothing to render; a zero-block row would still
        // pay row margins and inter-message spacing.
        guard !blocks.isEmpty else { return nil }
        return CodeMessageRow(id: id, role: rowRole, blocks: blocks)
    }

    /// The dedup key for one attachment: the server file id, or the payload
    /// identity before upload. Deliberately local, like `isReasoning`: the
    /// shared `V2AttachmentContent.cacheKey` extension is main-actor isolated
    /// under the package's default isolation, and this builder is
    /// `nonisolated`. The fallback matches that key's non-device branch (a
    /// pre-upload attachment is optimistic, so it never reads from a device
    /// path).
    private static func attachmentKey(_ file: V2AttachmentContent) -> String {
        file.fileId ?? "raw:\(file.raw.hashValue)"
    }

    /// The first message item's role (wire order). A row with no message item
    /// has no declared role, so it takes `.system`; a message item whose wire
    /// role is absent is `.unknown` rather than a guessed role.
    private static func role(of items: [V2TimelineItem]) -> V2MessageRole {
        guard let message = items.filter({ $0.type == .message })
            .sorted(by: wireOrder).first else {
            return .system
        }
        return message.role ?? .unknown
    }

    /// The tool rows of one message in their declared tool order.
    ///
    /// `source.blockIndex` is the ordering truth, but only when every tool row
    /// of the group declares one. If any row lacks it the target order is
    /// unknown, so the group stays in wire order (`orderSeq`) rather than
    /// guessing a position for the missing row — the server's rule
    /// (`_intra_message_target_rows`) and the "never guess" contract behind
    /// v2_43. Ties break on `(orderSeq, id)`, the same stable key the server
    /// and the client projection use.
    private static func orderedToolRows(_ tools: [V2TimelineItem]) -> [V2TimelineItem] {
        let indexed = tools.compactMap { tool -> (index: Int, item: V2TimelineItem)? in
            guard let index = tool.source["blockIndex"]?.intValue else { return nil }
            return (index, tool)
        }
        guard indexed.count == tools.count else {
            return tools.sorted(by: wireOrder)
        }
        return indexed.sorted { lhs, rhs in
            lhs.index == rhs.index ? wireOrder(lhs.item, rhs.item) : lhs.index < rhs.index
        }.map { $0.item }
    }

    /// Deliberately local: the shared `V2TimelineItem.isReasoning` extension is
    /// main-actor isolated under the package's default isolation, and this
    /// builder is `nonisolated`. Same predicate as the server's
    /// `_intra_message_kind`.
    private static func isReasoning(_ item: V2TimelineItem) -> Bool {
        item.type == .reasoning
            || (item.type == .system && item.raw["content"]?["kind"] == .string("reasoning"))
    }

    /// A wire `tool` row, or any row that declares `content.kind ==
    /// "file_change"`. The latter is how Codex publishes a file change as an
    /// artifact: the official page renders a file change in the collapsed tool
    /// span, so the row joins the message as a tool call (the profile's table
    /// resolves `file_change` to `.edit`) instead of becoming a generic row.
    private static func isToolRow(_ item: V2TimelineItem) -> Bool {
        item.type == .tool || item.type == .fileChange
            || item.raw["content"]?["kind"] == .string("file_change")
    }

    /// The rows a message stacks into its block list. Everything else (turn
    /// markers, notices, artifacts without a file-change kind) keeps its own
    /// row.
    private static func isStackable(_ item: V2TimelineItem) -> Bool {
        isReasoning(item) || item.type == .message || isToolRow(item)
    }

    /// `content.parentItemId` is the connector's L2 attribution of a row to
    /// the Agent card that owns it (same reader as `SubAgentProgress`); an
    /// empty value is absent.
    private static func isSubAgentChild(_ item: V2TimelineItem) -> Bool {
        TimelineText.first(item.raw["content"]?["parentItemId"]) != nil
    }

    private static func wireOrder(_ lhs: V2TimelineItem, _ rhs: V2TimelineItem) -> Bool {
        lhs.orderSeq == rhs.orderSeq ? lhs.id < rhs.id : lhs.orderSeq < rhs.orderSeq
    }
}
