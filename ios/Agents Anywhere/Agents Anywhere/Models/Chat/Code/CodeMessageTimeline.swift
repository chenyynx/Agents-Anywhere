import Foundation

// The Code page's row model: one official `DisplayMessage`-shaped row, made of
// the row's thinking run, its body, and its collapsed tool span.
//
// The official engine (1.261023.20 merge function `0x102fa3c24`; round27
// `01-tool-merge-and-turn-1023.md` §2) appends a new assistant message's
// `toolCalls` block into the most recent row whose tail block is `toolCalls`,
// skipping `thinkingContent` blocks. Text, attachments and every other block
// type stop that scan, and a turn end (`endsTurn`) stops it too. AA's wire is
// row-shaped, so `CodeMessageBuilder.units` runs the same scan over the
// declared row order (`orderSeq`) and emits three unit kinds:
//
//   .message    one message's body/reasoning plus the tool rows that belong to
//               that same message (its own `toolCalls` block),
//   .span       a cross-message tool run (serial tools share one row),
//   .standalone a row that keeps its own top-level item.
//
// The planner is the single source of the row sequence: `rows(for:)` renders
// it and `TimelineGrouping.codeGroups` groups it, so the view, the height
// measurer and the collection identity all see the same units.

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

/// One top-level Code row before it is turned into a `CodeMessageRow`.
///
/// A unit is the official `DisplayMessage` unit after the cross-message merge:
/// a message's body keeps its own tools, and a run of tool-only messages (with
/// their thinking) collapses into one span. The planner is idempotent — feeding
/// one unit's rows back in yields the same unit — because the collection
/// adapter, the row view and the height measurer all rebuild a group from its
/// own rows.
nonisolated enum CodeMessageUnit {
    /// A message's own row: body/reasoning rows plus the tool rows declared for
    /// that message (same `nativeMessageId ?? itemId`).
    case message(key: String, items: [V2TimelineItem])
    /// A cross-message tool run. `id` is the first tool row's stable
    /// `source.itemId` (the connector's `tool_use` id), or that row's id.
    case span(id: String, items: [V2TimelineItem])
    /// A row that is not stacked into a message or a span.
    case standalone(item: V2TimelineItem)

    var items: [V2TimelineItem] {
        switch self {
        case let .message(_, items): return items
        case let .span(_, items): return items
        case let .standalone(item): return [item]
        }
    }
}

nonisolated enum CodeMessageBuilder {
    /// A row's address while building a non-merging runtime's rows: a message
    /// group by its declared key, or a single row by its item id.
    ///
    /// The two cases are separate namespace entries, so a message key equal to
    /// a standalone item id still gets its own index entry rather than
    /// displacing the other row. Output ids stay as declared (`<message key>`
    /// and `item:<item id>`).
    private nonisolated enum LegacySlot: Hashable {
        case message(String)
        case item(String)
    }

    /// The unit a later tool row can append to: an open span, or a message row
    /// whose tail block is already `toolCalls`. A message row with only text
    /// or thinking is not a target — the official scan stops at the text block
    /// (`0x102fa403c`, round27 A §2.3).
    private nonisolated enum MergeTarget {
        case span(Int)
        case message(Int)
    }

    /// The enclosing assistant message id: `nativeMessageId` for a tool row,
    /// `itemId` for a body/reasoning row (server `timeline_message_group_key`).
    /// An empty string is absent, exactly as the server's `or` treats it.
    static func groupKey(for item: V2TimelineItem) -> String? {
        TimelineText.first(item.source["nativeMessageId"], item.source["itemId"])
    }

    /// Timeline rows → planner units, preserving wire order.
    ///
    /// `profile` supplies the runtime's segment policy and its observed
    /// name/kind table; the builder itself never switches on a runtime id. The
    /// runtime gate lives here: only a runtime with evidence for the official
    /// cross-message merge runs it (`CodeRuntimeProfile
    /// .mergesToolRowsAcrossMessages`); every other runtime keeps the declared
    /// message grouping.
    ///
    /// `interactionTargets` are row ids an approval card anchors on. Those rows
    /// always keep their own item, even when they are sub-agent children or a
    /// runtime would skip their call.
    ///
    /// `isTurnBoundary` is the injectable turn seam (rule 6): by default a user
    /// message row ends the run. `source.turnId` is the primary turn truth: a
    /// declared turn id that differs from the previous row's is a hard boundary
    /// (a scheduled turn publishes no user row), a row without one inherits the
    /// previous row's turn, and a sequence with no turn ids at all keeps the
    /// user-row-only behaviour. The change is detected inside one planning pass,
    /// so replanning a unit stays idempotent.
    static func units(for items: [V2TimelineItem],
                      profile: CodeRuntimeProfile,
                      interactionTargets: Set<String> = [],
                      isTurnBoundary: ((V2TimelineItem) -> Bool)? = nil,
                      includeSubAgentChildren: Bool = false) -> [CodeMessageUnit] {
        guard profile.mergesToolRowsAcrossMessages else {
            return legacyUnits(items, interactionTargets: interactionTargets,
                               includeSubAgentChildren: includeSubAgentChildren)
        }
        return mergedUnits(items, profile: profile,
                           interactionTargets: interactionTargets,
                           isTurnBoundary: isTurnBoundary ?? isUserTurnBoundary,
                           includeSubAgentChildren: includeSubAgentChildren)
    }

    /// Timeline rows → Code rows.
    ///
    /// For the Claude profile one unit is one row; the row ids of a span are the
    /// first tool's `tool_use` id, so a new serial call grows the same row
    /// instead of inserting a new top-level item.
    static func rows(for items: [V2TimelineItem],
                     profile: CodeRuntimeProfile,
                     includeSubAgentChildren: Bool = false) -> [CodeMessageRow] {
        units(for: items, profile: profile,
              includeSubAgentChildren: includeSubAgentChildren).compactMap { unit -> CodeMessageRow? in
            switch unit {
            case let .message(key, items):
                return messageRow(id: key, items: items, profile: profile)
            case let .span(id, items):
                return spanRow(id: id, items: items, profile: profile)
            case let .standalone(item):
                return CodeMessageRow(id: "item:\(item.id)",
                                      role: .system,
                                      blocks: [.other(id: item.id, type: item.type.rawValue)])
            }
        }
    }

    // MARK: - Planner (cross-message merge)

    /// The official merge over AA's row sequence (round27 A §1–§2).
    ///
    /// Rows arrive in `orderSeq` order. State:
    /// - a message row keeps its own tool rows through `messageIndexByKey`, so
    ///   an A-B-A interleaving still lands every A tool in A's row;
    /// - `target` is the row a *new* tool row appends to (the official tail
    ///   scan); a text/attachment/marker/interaction-target/turn-end row ends
    ///   it;
    /// - reasoning is transparent: it never breaks a run, it joins the unit it
    ///   arrives in, and a run that ends with only reasoning still keeps its
    ///   `思考过程` row.
    private static func mergedUnits(_ items: [V2TimelineItem],
                                    profile: CodeRuntimeProfile,
                                    interactionTargets: Set<String>,
                                    isTurnBoundary: (V2TimelineItem) -> Bool,
                                    includeSubAgentChildren: Bool) -> [CodeMessageUnit] {
        var units: [CodeMessageUnit] = []
        var messageIndexByKey: [String: Int] = [:]
        var target: MergeTarget?
        var pendingReasoning: [V2TimelineItem] = []
        var consumed: Set<String> = []
        /// The last declared turn among the rows seen so far. A row with no
        /// turnId inherits it; only a *declared* id that differs starts a turn.
        var currentTurnID: V2TurnID?
        /// The user message key already open. One user message may arrive as
        /// several body rows (one per content block); those rows share the key
        /// and must stay one row, so only a *new* user key ends the turn.
        var lastUserKey: String?

        func append(_ item: V2TimelineItem, to index: Int) {
            switch units[index] {
            case let .message(key, rows):
                units[index] = .message(key: key, items: rows + [item])
            case let .span(id, rows):
                units[index] = .span(id: id, items: rows + [item])
            case .standalone:
                return
            }
        }

        /// Thinking that arrived before the next unit is merged into it; a run
        /// of reasoning rows alone becomes its own `思考过程` row.
        func appendPending(to index: Int) {
            guard !pendingReasoning.isEmpty else { return }
            let rows = pendingReasoning
            pendingReasoning.removeAll()
            for row in rows { append(row, to: index) }
        }

        func flushPending() {
            guard !pendingReasoning.isEmpty else { return }
            let rows = pendingReasoning
            pendingReasoning.removeAll()
            if let key = rows.compactMap({ groupKey(for: $0) }).first {
                units.append(.message(key: key, items: rows))
            } else {
                for row in rows { units.append(.standalone(item: row)) }
            }
        }

        /// Ends the current tool run but not the turn: a later tool row opens a
        /// new span, while same-message tools can still find their own row.
        func breakRun() {
            target = nil
        }

        /// A user prompt (or an injected turn boundary): nothing before it can
        /// merge with anything after it.
        func endTurn() {
            target = nil
            messageIndexByKey.removeAll()
            lastUserKey = nil
        }

        /// True when `item` opens a new declared turn. The comparison is against
        /// the last declared turn id of this pass, not the immediately previous
        /// row, so a row without a turnId inherits the turn it belongs to and
        /// never invents a boundary (old payloads and message-only turn ids).
        func startsNewTurn(_ item: V2TimelineItem) -> Bool {
            guard let declaredTurnID = item.turnId else { return false }
            let changed = currentTurnID.map { $0 != declaredTurnID } ?? false
            currentTurnID = declaredTurnID
            return changed
        }

        for item in items.sorted(by: wireOrder) {
            // The projection hands over one version per item id. A repeated id
            // inside one call would duplicate a block or a tool segment, so the
            // first occurrence wins.
            guard consumed.insert(item.id).inserted else { continue }
            let isChild = isSubAgentChild(item)
            let userKey = item.type == .message && item.role == .user
                ? groupKey(for: item) : nil
            let repeatsUserMessage = userKey != nil && userKey == lastUserKey

            // A declared turn change is a hard boundary: nothing before it may
            // merge with anything after it. Thinking before the boundary
            // belongs to the finished turn. A payload with no turn ids at all
            // keeps the user-row-only seam. Sub-agent child rows are not part
            // of this timeline and may carry a sub-agent-local fallback turn id
            // (`turn_claude_subagent_*`), so they never advance the turn state.
            // A user message's own later body rows share its key and are part
            // of the same turn, so they must not reopen the boundary.
            if !isChild,
               startsNewTurn(item) || (!repeatsUserMessage && isTurnBoundary(item)) {
                flushPending()
                endTurn()
            }
            if let userKey { lastUserKey = userKey }

            // An approval card anchors on this row: it has to stay its own
            // item, and it ends the run exactly like any other break.
            if interactionTargets.contains(item.id) {
                flushPending()
                breakRun()
                units.append(.standalone(item: item))
                continue
            }
            // Sub-agent child rows stay in the panel, not the main timeline.
            // A child row never breaks a run; the panel opts in to render
            // them with the same builder.
            if !includeSubAgentChildren, isChild { continue }

            if isToolRow(item) {
                // `ExitPlanMode` and an answered `AskUserQuestion` are pulled
                // out of the tool block: they neither render nor break the
                // span (round27 C A2). A *transient* question reaches this
                // planner only as an interaction target and was handled above.
                if profile.skippedToolNames.contains(CodeToolCall.wireName(for: item)) {
                    continue
                }
                guard let key = groupKey(for: item) else {
                    // No declared grouping key: the row cannot join a span.
                    flushPending()
                    breakRun()
                    units.append(.standalone(item: item))
                    continue
                }
                // The Agent card is the official `threadSessionCard` shape: it
                // flushes the span and keeps its own row instead of merging
                // into the surrounding run (round23 §4.3; no `blockIndex` is
                // the connector's card shape).
                if isAgentCardWithoutBlockIndex(item) {
                    flushPending()
                    breakRun()
                    units.append(.span(id: spanID(for: item), items: [item]))
                    continue
                }
                // This tool belongs to a message that already has a row: the
                // message's own `toolCalls` block (A-B-A included).
                if let index = messageIndexByKey[key] {
                    appendPending(to: index)
                    append(item, to: index)
                    target = .message(index)
                    continue
                }
                // Cross-message merge: append to the row the official tail
                // scan would find.
                if let target {
                    switch target {
                    case let .span(index), let .message(index):
                        appendPending(to: index)
                        append(item, to: index)
                    }
                    continue
                }
                var rows = pendingReasoning
                pendingReasoning.removeAll()
                rows.append(item)
                units.append(.span(id: spanID(for: item), items: rows))
                target = .span(units.count - 1)
                continue
            }

            if isReasoning(item) {
                guard let key = groupKey(for: item) else {
                    flushPending()
                    breakRun()
                    units.append(.standalone(item: item))
                    continue
                }
                // Thinking is transparent (rule 3): whatever row is open —
                // a cross-message span or a message row that already holds
                // tools — keeps it. The official thinking merger backscans
                // the same way, skipping `toolCalls` and joining the earliest
                // `thinkingContent` (`0x102fa55b0`; round27 B §1).
                if let target {
                    switch target {
                    case let .span(index), let .message(index):
                        append(item, to: index)
                    }
                } else if let index = messageIndexByKey[key] {
                    // A body-only row of this message is already open.
                    append(item, to: index)
                } else {
                    // It waits for the next unit (a body of the same message
                    // or a tool run); a run that ends here still renders it.
                    pendingReasoning.append(item)
                }
                continue
            }

            // A body row, or any other row the Code page does not stack.
            if isStackable(item), let key = groupKey(for: item) {
                if !pendingReasoning.isEmpty,
                   !pendingReasoning.contains(where: { groupKey(for: $0) == key }) {
                    flushPending()
                }
                if let index = messageIndexByKey[key] {
                    appendPending(to: index)
                    append(item, to: index)
                    // A user prompt is never a merge target; an assistant row
                    // becomes one only once a tool lands in it.
                    target = containsToolRows(units[index]) ? MergeTarget.message(index) : nil
                } else {
                    var rows = pendingReasoning
                    pendingReasoning.removeAll()
                    rows.append(item)
                    units.append(.message(key: key, items: rows))
                    // Later body rows of the same message find this row. A
                    // tool row never shares a user message key, so keeping the
                    // user key here cannot merge tools across the prompt.
                    messageIndexByKey[key] = units.count - 1
                    target = nil
                }
                continue
            }

            // A marker/compact, a foreign artifact, or a body with no declared
            // key: it keeps its own item and stops the run.
            flushPending()
            breakRun()
            units.append(.standalone(item: item))
        }

        flushPending()
        return units
    }

    /// The pre-round27 grouping: one message key = one row, first-seen key
    /// order. Codex/DSH/generic keep this until their own engine is read.
    private static func legacyUnits(_ items: [V2TimelineItem],
                                    interactionTargets: Set<String>,
                                    includeSubAgentChildren: Bool) -> [CodeMessageUnit] {
        var order: [LegacySlot] = []
        var seen: Set<LegacySlot> = []
        var consumed: Set<String> = []
        var grouped: [String: [V2TimelineItem]] = [:]
        var standalone: [String: V2TimelineItem] = [:]

        for item in items {
            guard consumed.insert(item.id).inserted else { continue }
            if interactionTargets.contains(item.id) {
                standalone[item.id] = item
                let slot = LegacySlot.item(item.id)
                if seen.insert(slot).inserted { order.append(slot) }
                continue
            }
            if !includeSubAgentChildren, isSubAgentChild(item) { continue }
            if isStackable(item), let key = groupKey(for: item) {
                let slot = LegacySlot.message(key)
                if seen.insert(slot).inserted { order.append(slot) }
                grouped[key, default: []].append(item)
            } else {
                standalone[item.id] = item
                let slot = LegacySlot.item(item.id)
                if seen.insert(slot).inserted { order.append(slot) }
            }
        }

        return order.compactMap { slot -> CodeMessageUnit? in
            switch slot {
            case let .message(key):
                guard let items = grouped[key] else { return nil }
                return .message(key: key, items: items)
            case let .item(id):
                guard let item = standalone[id] else { return nil }
                return .standalone(item: item)
            }
        }
    }

    private static func isUserTurnBoundary(_ item: V2TimelineItem) -> Bool {
        item.type == .message && item.role == .user
    }

    private static func containsToolRows(_ unit: CodeMessageUnit) -> Bool {
        unit.items.contains(where: isToolRow)
    }

    /// The Agent card is the connector's `content.kind == "agent_call"` row,
    /// and its card shape declares no `blockIndex` (round23 §1.2d: every
    /// production card is missing it). It stays its own row.
    private static func isAgentCardWithoutBlockIndex(_ item: V2TimelineItem) -> Bool {
        item.raw["content"]?["kind"] == .string("agent_call")
            && item.source["blockIndex"]?.intValue == nil
    }

    /// The span's stable address: the `tool_use` id the connector declares as
    /// `source.itemId` (stable across live and history), else the row id. The
    /// first tool row fixes it, so a later call arriving in the same run cannot
    /// rename the row and drop its measured height.
    private static func spanID(for item: V2TimelineItem) -> String {
        TimelineText.first(item.source["itemId"]) ?? item.id
    }

    // MARK: - Rows

    private static func messageRow(id: String, items: [V2TimelineItem],
                                   profile: CodeRuntimeProfile) -> CodeMessageRow? {
        let reasoning = items.filter(isReasoning).sorted(by: wireOrder)
        let bodies = items.filter { !isReasoning($0) && $0.type == .message }.sorted(by: wireOrder)
        let toolRows = orderedToolRows(items.filter(isToolRow), profile: profile)
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
        // reasoning row per streamed block, so the merge happens here. Text
        // between two runs would break the run in the official engine; the
        // server's RBT order already places body rows after all reasoning
        // rows, so this client cannot see that interleaving and merges the
        // group's reasoning rows in wire order instead.
        appendReasoningBlock(reasoning, to: &blocks)
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

    /// One cross-message tool run. The merged thinking block sits before the
    /// span, the official common shape `[thinkingContent, toolCalls]`.
    private static func spanRow(id: String, items: [V2TimelineItem],
                                profile: CodeRuntimeProfile) -> CodeMessageRow? {
        let reasoning = items.filter(isReasoning).sorted(by: wireOrder)
        let toolRows = items.filter(isToolRow).sorted(by: wireOrder)
        let calls = toolRows.map { item in
            CodeToolCall(item: item,
                         kind: profile.kind(for: CodeToolCall.wireName(for: item),
                                            wireKind: CodeToolCall.wireKind(for: item)))
        }
        let segments = CodeToolSegmenter.segments(calls, policy: profile.segmentPolicy)
        var blocks: [CodeMessageRow.Block] = []
        appendReasoningBlock(reasoning, to: &blocks)
        if !segments.isEmpty { blocks.append(.toolCalls(segments)) }
        guard !blocks.isEmpty else { return nil }
        // No body row exists in a span, so it declares no role (`.system`),
        // exactly like the old tool-only message row.
        return CodeMessageRow(id: id, role: .system, blocks: blocks)
    }

    /// One merged `Block.thinkingContent`: `[old, new]` texts joined with a
    /// blank line, the first row's id, and `running` while any run is still
    /// open (`0x102fa55b0`; round27 B §1/§3).
    private static func appendReasoningBlock(_ reasoning: [V2TimelineItem],
                                             to blocks: inout [CodeMessageRow.Block]) {
        // Only settled reasoning belongs to the persistent `thinkingContent`
        // block. A running row is the live turn's working line; including it
        // would flip the merged block to `.running` and hide the entire
        // settled text while the next segment streams (the `思考过程` row was
        // observed disappearing and reappearing on 2026-10-28). Official keeps
        // the live thinking state and the completed block separate.
        let settledRows = reasoning.filter { $0.status == .done }
        let text = settledRows
            .map(\.displayText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty, let first = settledRows.first else { return }
        blocks.append(.reasoning(id: first.id, text: text, status: .done))
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

    /// The tool rows of one unit in their declared order.
    ///
    /// The merged planner orders a span by `orderSeq` (the only sequence truth
    /// across messages; every message restarts `blockIndex` at 0, so sorting a
    /// cross-message run by it would interleave messages). The legacy
    /// per-message grouping keeps its old correction: `source.blockIndex` when
    /// every tool row declares one, else wire order — the server's rule
    /// (`_intra_message_target_rows`) and the "never guess" contract behind
    /// v2_43. Ties break on `(orderSeq, id)`, the same stable key the server
    /// and the client projection use.
    private static func orderedToolRows(_ tools: [V2TimelineItem],
                                        profile: CodeRuntimeProfile) -> [V2TimelineItem] {
        guard !profile.mergesToolRowsAcrossMessages else {
            return tools.sorted(by: wireOrder)
        }
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
