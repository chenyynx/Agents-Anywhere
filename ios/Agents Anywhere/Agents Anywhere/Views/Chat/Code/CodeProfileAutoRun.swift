#if DEBUG
import Foundation
import Observation
import SwiftUI
import UIKit

// C5 Code-profile gate (W8).
//
// The app root swaps to this screen only when the process is launched with
// `aa-code-profile`. The gate never touches a session or the network: it
// builds three minimal wire fixtures (Claude / Codex / DSH), runs them through
// the Code page's pure model (message grouping, RBT block order, runtime tool
// segmentation), drives W6's publisher with an injected clock, parses W4's
// five output cases, and finally renders the real Code row, tool detail and
// working mark on screen and captures them as PNGs.
//
// Outputs (written to the app's Documents directory, where the CI job copies
// them out of the simulator container):
//   - code-profile.json       — failures / completed / phase / scenario details
//   - code-message-row.png    — CodeMessageRowView with a user bubble, a
//                               settled reasoning line and collapsed tool rows
//   - code-detail.png         — the single-call page: a long Read output
//                               (the blank-card regression) with real glyphs
//   - code-detail-group.png   — the span summary page: title + call list
//   - code-working-mark.png   — the 20 pt working mark beside its status text
//   - code-collapsed-rows.png — the R28 row gallery (single / multi / failed
//                               / diff / thinking / pure text)
//   - code-collapsed-rows-dark.png — the same gallery under dark tokens
//
// `completed` is only true in the final write. Every earlier phase writes a
// checkpoint with `completed: false`, so a crash mid-gate still leaves the last
// finished phase and its assertions on disk for the CI assertion step.

/// One row in the collapsed-row gallery. `thinking` renders `CodeThinkingRow`
/// (the same shared component); every other item renders a tool row.
struct CodeCollapsedRowFixture: Identifiable {
    enum Kind {
        case tool
        case thinking
    }

    let id: String
    let kind: Kind
    let label: CodeToolRowLabel
    let icon: String?
    let status: CodeToolStatus
    let failureExtent: CodeFailureExtent?
    let hasDetails: Bool
    var workingMark: WorkingMarkBody? = nil

    /// The row's exact default-size height from the R28 layout: the tallest
    /// child (24 pt icon/caret slot, 21 pt text line) plus 6 pt padding a
    /// side. A row with neither a drawn icon nor a caret is the 33 pt
    /// pure-text case. Every 1023 tool row is built with a concrete icon
    /// (`0x1033b901c` / `0x1033b8b20`), so any row with an icon measures 36.
    var expectedDefaultHeight: CGFloat {
        (icon != nil || hasDetails) ? 36 : 33
    }
}

@MainActor
extension CodeCollapsedRowFixture {
    /// One gallery row. The root view renders this for the screenshots and
    /// the height leg hosts the same view, so the capture and the measured
    /// height cannot diverge.
    @ViewBuilder
    func rowView() -> some View {
        switch kind {
        case .thinking:
            CodeThinkingRow {}
        case .tool:
            CodeCollapsedToolRow(label: label,
                                 icon: icon,
                                 workingMark: workingMark,
                                 status: status,
                                 failureExtent: failureExtent,
                                 hasDetails: hasDetails) {}
        }
    }
}

@MainActor
@Observable
final class CodeProfileAutoRunModel {

    static let launchArgument = "aa-code-profile"
    static let resultFileName = "code-profile.json"

    /// Which component the root view shows while the gate captures it.
    enum Stage: Equatable {
        case idle
        case messageRow
        case detail
        case detailGroup
        case workingMark
        case thinkingStatus
        case scrollDown
        case collapsedRows
        case collapsedRowsDark
    }

    private(set) var stage: Stage = .idle
    private(set) var messageGroup: ChatTimelineGroup?
    /// The single-call page fixture (a long Read result: the blank-card
    /// regression).
    private(set) var detailCall: CodeToolCall?
    /// The group page fixture: the summary layer plus its call list.
    private(set) var detailGroupCalls: [CodeToolCall] = []
    /// The collapsed-row gallery rendered by the two dedicated capture
    /// stages (light and dark).
    private(set) var rowGallery: [CodeCollapsedRowFixture] = []

    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var report: [String: Any] = [:]
    @ObservationIgnored private var didRun = false
    @ObservationIgnored private var didPrepareViews = false

    // MARK: - Run

    func run() async {
        guard !didRun else { return }
        didRun = true
        // Let the window, its trait collection and the render server settle.
        await wait(400)

        runRuntimeFixtures()
        persist(phase: "runtimes")

        runStreaming()
        persist(phase: "streaming")

        runToolOutput()
        persist(phase: "toolOutput")

        runToolLabels()
        persist(phase: "toolLabels")

        runCollapsedRowFixtures()
        persist(phase: "collapsedRows")

        await captureViews()
        finish()
    }

    // MARK: - Runtime fixtures

    /// The official `AttachmentTileLayout` has three shapes for three items,
    /// not one: wide on top, wide on the bottom, or the 2+1 fallback
    /// (`attachment-tiles-arrangement.md` §1). The height matrix cannot tell
    /// them apart (all are 288 pt), so the gate checks the shapes directly.
    private func verifyAttachmentGridShapes() {
        let cases: [(name: String, count: Int, wideFirst: Bool, wideLast: Bool,
                     expected: [String])] = [
            ("one", 1, false, false, ["large"]),
            ("two", 2, false, false, ["square,square"]),
            ("three-wide-first", 3, true, false, ["wide", "square,square"]),
            ("three-wide-last", 3, false, true, ["square,square", "wide"]),
            ("three-fallback", 3, false, false, ["square,square", "filler,square"]),
            ("four", 4, false, false, ["square,square", "square,square"]),
            ("five", 5, false, false, ["square,square", "square,square+n"]),
        ]
        for item in cases {
            let rows = CodeAttachmentGridPlan.rows(
                count: item.count, wideFirst: item.wideFirst, wideLast: item.wideLast)
            let actual = rows.map { row in
                row.map { placement -> String in
                    if placement.isFiller { return "filler" }
                    switch placement.size {
                    case .square: return placement.overflow == nil ? "square" : "square+n"
                    case .wide: return "wide"
                    case .large: return "large"
                    }
                }.joined(separator: ",")
            }
            check(actual == item.expected,
                  "attachmentLayout \(item.name): \(actual), expected \(item.expected)")
        }
        // The view's [I] three-item predicate: landscape = wide, a missing
        // size is not wide (three files therefore fall to 2+1).
        check(CodeAttachmentGridPlan.isWide(
            pixelSize: CGSize(width: 400, height: 300)),
              "attachmentLayout predicate: landscape should be wide")
        check(!CodeAttachmentGridPlan.isWide(
            pixelSize: CGSize(width: 300, height: 400)),
              "attachmentLayout predicate: portrait should not be wide")
        check(!CodeAttachmentGridPlan.isWide(pixelSize: nil),
              "attachmentLayout predicate: no size should not be wide")
        report["attachmentLayout"] = ["cases": cases.count]
    }

    /// A Markdown link must carry both the visible underline and the real
    /// `NSAttributedString.Key.link` URL. 594–596 only underlined the text;
    /// the converter dropped the destination, so UITextView never made it
    /// interactive.
    private func verifyLinkAttribute() {
        let category = DynamicTypeSize.large.contentSizeCategory
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: String(describing: DynamicTypeSize.large),
            layoutDirection: 0,
            boldText: false,
            scale: CodePageTheme.markdownScale)
            .resolvedForCodePage(category: category)
        let target = "https://example.com/release"
        let text = "[release](\(target))"
        guard let document = AssistantMarkdownDocumentParser.make(
            text: text,
            resolvesFileReferences: false,
            typography: typography,
            codeStyle: CodePageTheme.codeCardStyle(category: category))?
            .applyingCodePageTextColors() else {
            failures.append("links: markdown parse failed")
            return
        }
        let attributed = document.blocks.compactMap { block -> NSAttributedString? in
            guard case let .text(text) = block else { return nil }
            return text.attributed
        }.first
        guard let attributed else {
            failures.append("links: no text block")
            return
        }
        let range = (attributed.string as NSString).range(of: "release")
        guard range.location != NSNotFound,
              let url = attributed.attribute(.link, at: range.location,
                                             effectiveRange: nil) as? URL else {
            failures.append("links: .link missing at \(range)")
            return
        }
        check(url.absoluteString == target,
              "links: \(url.absoluteString), expected \(target)")
        let underline = attributed.attribute(.underlineStyle, at: range.location,
                                             effectiveRange: nil) as? Int
        check(underline == NSUnderlineStyle.single.rawValue,
              "links: underline \(String(describing: underline)), expected 1")
        report["links"] = ["url": url.absoluteString,
                           "underline": underline ?? -1]
    }

    private struct RuntimeFixture {
        let name: String
        let family: CodeRuntimeProfile.Family
        let profile: CodeRuntimeProfile
        let messageID: String
        let unknownID: String
        let skippedIDs: [String]
        let expectsSpecial: Bool
        let expectedBlocks: [String]
        let expectedSegments: [String]
        let expectedKinds: [CodeToolKind]
        let json: String
    }

    private func runRuntimeFixtures() {
        verifyAttachmentGridShapes()
        verifyLinkAttribute()
        var scenarios: [String: Any] = [:]
        for fixture in Self.runtimeFixtures {
            guard let items = Self.decodeItems(fixture.json) else {
                failures.append("\(fixture.name): fixture JSON did not decode")
                continue
            }

            check(fixture.profile.family == fixture.family,
                  "\(fixture.name): profile family \(fixture.profile.family.rawValue), expected \(fixture.family.rawValue)")

            let rows = CodeMessageBuilder.rows(for: items, profile: fixture.profile)
            check(rows.count == 1, "\(fixture.name): \(rows.count) rows, expected 1")
            guard let row = rows.first else { continue }

            check(row.id == fixture.messageID,
                  "\(fixture.name): row id \(row.id), expected \(fixture.messageID)")
            check(row.role == .assistant,
                  "\(fixture.name): row role \(row.role.rawValue), expected assistant")

            let blocks = Self.blockDescriptors(row.blocks)
            check(blocks == fixture.expectedBlocks,
                  "\(fixture.name): blocks \(blocks), expected \(fixture.expectedBlocks)")

            guard let lastBlock = row.blocks.last,
                  case let .toolCalls(segments) = lastBlock else {
                failures.append("\(fixture.name): no trailing toolCalls block")
                continue
            }

            let descriptors = segments.map(Self.descriptor)
            check(descriptors == fixture.expectedSegments,
                  "\(fixture.name): segments \(descriptors), expected \(fixture.expectedSegments)")

            let calls = Self.flatten(segments)
            let kinds = calls.map(\.kind)
            check(kinds == fixture.expectedKinds,
                  "\(fixture.name): kinds \(kinds.map { String(describing: $0) }), expected \(fixture.expectedKinds.map { String(describing: $0) })")

            let ids = calls.map(\.id)
            check(ids.contains(fixture.unknownID),
                  "\(fixture.name): unknown tool \(fixture.unknownID) left the span")
            let unknownKind = calls.first(where: { $0.id == fixture.unknownID })
                .map { String(describing: $0.kind) } ?? "missing"
            check(unknownKind == String(describing: CodeToolKind.other),
                  "\(fixture.name): unknown tool kind \(unknownKind), expected other")

            for skipped in fixture.skippedIDs {
                check(!ids.contains(skipped),
                      "\(fixture.name): skipped call \(skipped) reached a segment")
            }

            let specials = descriptors.filter { $0.hasPrefix("special(") }
            if fixture.expectsSpecial {
                check(specials.count == 1,
                      "\(fixture.name): \(specials.count) special segments, expected 1")
            } else {
                check(specials.isEmpty,
                      "\(fixture.name): unexpected special segments \(specials)")
            }

            scenarios[fixture.name] = [
                "family": fixture.family.rawValue,
                "rowCount": rows.count,
                "rowIDs": rows.map(\.id),
                "role": row.role.rawValue,
                "blocks": blocks,
                "segments": descriptors,
                "kinds": kinds.map { String(describing: $0) },
                "unknownKind": unknownKind,
            ] as [String: Any]
        }
        report["runtimes"] = scenarios
    }

    private static func blockDescriptors(_ blocks: [CodeMessageRow.Block]) -> [String] {
        blocks.map { block in
            switch block {
            case let .reasoning(id, _, _): return "reasoning:\(id)"
            case let .text(id, _): return "text:\(id)"
            case let .attachments(id, files, _): return "attachments:\(id):\(files.count)"
            case .toolCalls: return "toolCalls"
            case let .other(id, _): return "other:\(id)"
            }
        }
    }

    private static func descriptor(_ segment: CodeToolSegment) -> String {
        switch segment {
        case let .span(calls):
            return "span(" + calls.map(\.id).joined(separator: ",") + ")"
        case let .special(kind, call):
            return "special(\(kind),\(call.id))"
        }
    }

    private static func flatten(_ segments: [CodeToolSegment]) -> [CodeToolCall] {
        segments.flatMap { segment -> [CodeToolCall] in
            switch segment {
            case let .span(calls): return calls
            case let .special(_, call): return [call]
            }
        }
    }

    // MARK: - Streaming (W6)

    private func runStreaming() {
        let epsilon: TimeInterval = 1e-9
        let eight = "one two three four five six seven eight "
        let burst = (1...20).map { "w\($0)" }.joined(separator: " ") + " "
        let backlog = (1...40).map { "b\($0)" }.joined(separator: " ") + " "
        let chinese = String(repeating: "你", count: 20)

        var streaming: [String: Any] = [:]

        // 0.1 s leading-edge throttle: the first snapshot publishes whole, a
        // second burst inside the window only marks pending, the next event
        // after the window flushes it.
        var leading = CodeStreamingPublisher()
        let first = leading.receive(delta: eight, at: 0)
        check(first?.text == eight,
              "streaming: first snapshot \(first?.text ?? "nil"), expected the whole first buffer")
        check(first?.id == CodeStreamingSnapshot.streamingRowID,
              "streaming: first snapshot id \(first?.id ?? "nil")")
        let blocked = leading.receive(delta: eight, at: 0.05)
        check(blocked == nil, "streaming: a snapshot published inside the 0.1 s window")
        check(leading.publishPending,
              "streaming: a blocked publish did not set publishPending")
        let flushed = leading.flush(at: 0.1 + epsilon)
        check(flushed?.text == eight + eight,
              "streaming: throttled flush \(flushed?.text ?? "nil")")
        check(flushed?.id == CodeStreamingSnapshot.streamingRowID,
              "streaming: throttled snapshot id \(flushed?.id ?? "nil")")
        streaming["leadingEdge"] = [
            "first": first?.text ?? "",
            "blocked": blocked == nil,
            "flushed": flushed?.text ?? "",
        ] as [String: Any]

        // Snapshot content: the whole current text, never a 4–8 word chunk.
        // A burst that arrives inside the throttle window only marks pending;
        // the first event after the window publishes the same full text in one
        // snapshot (CANONICAL/03-streaming.md §5.1/§4.3). The video's 4–8 word
        // / 50–100 ms cadence is an observation of network delta grouping, not
        // a client-side split (§9.2).
        var wholeText = seededPublisher()
        let insideWindow = wholeText.receive(delta: burst, at: 0.05)
        check(insideWindow == nil, "streaming: a burst published inside the 0.1 s window")
        check(wholeText.publishPending,
              "streaming: a throttled burst did not set publishPending")
        let wholeSnapshot = wholeText.flush(at: 0.1 + epsilon)
        check(wholeSnapshot?.text == "seed " + burst,
              "streaming: the open window did not publish the whole text "
                  + "\(wholeSnapshot?.text ?? "nil")")
        let emptyTick = wholeText.flush(at: 0.2 + epsilon)
        check(emptyTick == nil, "streaming: an empty tick published another snapshot")
        streaming["chunks"] = [
            "first": wholeSnapshot?.text ?? "",
            "second": emptyTick?.text ?? "",
            "third": "",
        ] as [String: Any]

        // Unspaced text (CJK) is published whole as well: there is no word
        // scanner left, so no character-count fallback can split it.
        var cjk = seededPublisher()
        let cjkFirst = cjk.receive(delta: chinese, at: 0.1)
        check(cjkFirst?.text == "seed " + chinese,
              "streaming: Chinese text was split \(cjkFirst?.text ?? "nil")")
        let cjkRest = cjk.flush(at: 0.2 + epsilon)
        check(cjkRest == nil, "streaming: Chinese text published twice")
        streaming["chinese"] = [
            "first": cjkFirst?.text ?? "",
            "rest": cjkRest?.text ?? "",
        ] as [String: Any]

        // Catch-up: the first snapshot and the first event after a pause
        // publish everything received so far.
        var catchUp = CodeStreamingPublisher()
        let catchUpFirst = catchUp.receive(delta: backlog, at: 0)
        check(catchUpFirst?.text == backlog,
              "streaming: the first snapshot did not publish the whole backlog")
        var catchUpAfterSeed = seededPublisher()
        let catchUpBacklog = catchUpAfterSeed.receive(delta: backlog, at: 0.1)
        check(catchUpBacklog?.text == "seed " + backlog,
              "streaming: a backlog arriving after the window was not published whole")
        streaming["catchUp"] = [
            "first": catchUpFirst?.text ?? "",
            "afterSeed": catchUpBacklog?.text ?? "",
        ] as [String: Any]

        // Completion is exempt from the throttle: the buffered tail must ride
        // the final snapshot even when it arrived inside the window
        // (CANONICAL/03-streaming.md §5.1).
        var doneInsideWindow = seededPublisher()
        _ = doneInsideWindow.receive(delta: "one two ", at: 0.05)
        let completeInside = doneInsideWindow.complete(at: 0.06)
        check(completeInside?.text == "seed one two ",
              "streaming: completion lost the throttled tail "
                  + "\(completeInside?.text ?? "nil")")
        check(completeInside?.isComplete == true,
              "streaming: completion inside the window is not marked complete")

        // Completion keeps the fixed row identity and flushes the rest.
        var done = seededPublisher()
        _ = done.receive(delta: "one two ", at: 0.1)
        let completion = done.complete(at: 0.12)
        check(completion?.isComplete == true, "streaming: completion is not marked complete")
        check(completion?.text == "seed one two ",
              "streaming: completion text \(completion?.text ?? "nil")")
        check(completion?.id == CodeStreamingSnapshot.streamingRowID,
              "streaming: completion changed the row identity")
        check(done.receive(delta: "three ", at: 0.13) == nil,
              "streaming: text was accepted after completion")
        streaming["completion"] = [
            "text": completion?.text ?? "",
            "isComplete": completion?.isComplete ?? false,
        ] as [String: Any]

        report["streaming"] = streaming
    }

    private func seededPublisher() -> CodeStreamingPublisher {
        var publisher = CodeStreamingPublisher()
        _ = publisher.receive(delta: "seed ", at: 0)
        return publisher
    }

    // MARK: - Tool output (W4)

    private enum OutputExpectation {
        case text(String)
        case todos([CodeToolTodo.Status])
        case diff(added: Int, removed: Int)
        case answers(question: String, answer: String)
        case approvedPlan
        case empty
    }

    private func runToolOutput() {
        let cases: [(name: String, kind: CodeToolKind,
                     expectation: OutputExpectation, json: String)] = [
            ("text", .bash, .text("hello from bash"), Self.textOutputJSON),
            ("todos", .todo, .todos([.completed, .inProgress, .pending]), Self.todosOutputJSON),
            ("diff", .edit, .diff(added: 1, removed: 1), Self.diffOutputJSON),
            ("answers", .question,
             .answers(question: "Which file?", answer: "TimelineTests.swift"),
             Self.answersOutputJSON),
            ("plan", .plan, .approvedPlan, Self.planOutputJSON),
            ("editInput", .edit, .empty, Self.editInputOutputJSON),
        ]

        var outputs: [String: Any] = [:]
        for testCase in cases {
            guard let item = Self.decodeItem(testCase.json) else {
                failures.append("toolOutput \(testCase.name): fixture JSON did not decode")
                continue
            }
            let output = CodeToolOutput(item: item, kind: testCase.kind)
            let matched = Self.matches(output, testCase.expectation)
            check(matched, "toolOutput \(testCase.name): parsed \(Self.describe(output))")
            outputs[testCase.name] = [
                "parsed": Self.describe(output),
                "matched": matched,
            ] as [String: Any]
        }
        report["toolOutput"] = outputs
    }

    private static func matches(_ output: CodeToolOutput,
                                _ expectation: OutputExpectation) -> Bool {
        switch (expectation, output) {
        case let (.text(expected), .text(actual)):
            return actual == expected
        case let (.todos(expected), .todos(actual)):
            return actual.map(\.status) == expected
        case let (.diff(added, removed), .diff(diff)):
            return diff.added == added && diff.removed == removed
        case let (.answers(question, answer), .submittedAnswers(answers)):
            return answers.count == 1
                && answers[0].question == question
                && answers[0].answer == answer
        case (.approvedPlan, .approvedPlan):
            return true
        case (.empty, .none):
            return true
        default:
            return false
        }
    }

    private static func describe(_ output: CodeToolOutput) -> String {
        switch output {
        case let .text(text): return "text(\(text.prefix(40)))"
        case let .todos(todos): return "todos(\(todos.count))"
        case let .diff(diff):
            return "diff(lines:\(diff.lines.count),+\(diff.added),-\(diff.removed))"
        case let .submittedAnswers(answers): return "answers(\(answers.count))"
        case .approvedPlan: return "approvedPlan"
        case .none: return "none"
        }
    }

    // MARK: - Collapsed row labels (W3)

    /// Device report 2026-10-23: six edits to one file rendered as
    /// "Edited 6 files". The official summary counts files, and a span whose
    /// calls all touch one file keeps the single-file shape.
    private func runToolLabels() {
        let path = "/home/ubuntu/.claude/projects/-home-ubuntu/memory/MEMORY.md"
        var calls: [CodeToolCall] = []
        for index in 0..<6 {
            let json = """
            {"id":"label-\(index)","sessionId":"gate-label","type":"tool","status":"done",
             "orderSeq":\(index + 1),
             "content":{"toolName":"Edit","input":{"file_path":"\(path)",
               "old_string":"a","new_string":"b","replace_all":false}},
             "source":{"itemId":"label-\(index)","nativeMessageId":"msg-label",
               "blockIndex":\(index)}}
            """
            guard let item = Self.decodeItem(json) else {
                failures.append("toolLabels: fixture \(index) did not decode")
                continue
            }
            calls.append(CodeToolCall(item: item, kind: .edit))
        }
        let plan = CodeToolLabelPlan.make(calls: calls, cwd: nil)
        let label = CodeToolLabels.label(for: calls, cwd: nil)
        let text = [label.verb, label.target].compactMap { $0 }.joined(separator: " ")
        let singleShape = plan?.verb == .edited
            && plan?.target == path
            && plan?.phrases.isEmpty == true
        let wrongCount = text.contains("6 file")
        check(singleShape, "toolLabels: six edits to one file lost the single-file shape (\(text))")
        check(!wrongCount, "toolLabels: six edits to one file summarized as \(text)")

        // Official Write has two verbs; the kind is derived from the result
        // text (production marker, 2026-10-25). The app-target mapping must
        // pick Updated for an update and Created for a create.
        let updateJSON = """
        {"id":"label-wu","sessionId":"gate-label","type":"tool","status":"done","orderSeq":1,
         "content":{"toolName":"Write","input":{"file_path":"/repo/Updated.swift"},
           "text":"The file /repo/Updated.swift has been updated successfully. (file state is current in your context — no need to Read it back)"},
         "source":{"itemId":"label-wu","nativeMessageId":"msg-label-wu","blockIndex":0}}
        """
        let createJSON = """
        {"id":"label-wc","sessionId":"gate-label","type":"tool","status":"done","orderSeq":1,
         "content":{"toolName":"Write","input":{"file_path":"/repo/Created.swift"},
           "text":"File created successfully at: /repo/Created.swift (file state is current in your context — no need to Read it back)"},
         "source":{"itemId":"label-wc","nativeMessageId":"msg-label-wc","blockIndex":0}}
        """
        let updateCall = Self.decodeItem(updateJSON).map { CodeToolCall(item: $0, kind: .write) }
        let createCall = Self.decodeItem(createJSON).map { CodeToolCall(item: $0, kind: .write) }
        let updatePlan = updateCall.flatMap { CodeToolLabelPlan.make(calls: [$0], cwd: nil) }
        let updateLabel = updateCall.map { CodeToolLabels.label(for: [$0], cwd: nil) }
        let createLabel = createCall.map { CodeToolLabels.label(for: [$0], cwd: nil) }
        let updateVerb = updateLabel?.verb ?? "nil"
        let createVerb = createLabel?.verb ?? "nil"
        check(updatePlan?.verb == .updated,
              "toolLabels: update Write plan verb \(String(describing: updatePlan?.verb)), expected updated")
        check(updateVerb == String(localized: "ccr_write_updated"),
              "toolLabels: update Write rendered \(updateVerb)")
        check(createVerb == String(localized: "ccr_verb_created"),
              "toolLabels: create Write rendered \(createVerb)")

        report["toolLabels"] = ["text": text,
                                "singleShape": singleShape,
                                "wrongCount": wrongCount,
                                "updateWriteVerb": updateVerb,
                                "createWriteVerb": createVerb]
    }

    // MARK: - Collapsed row fixtures (R28)

    /// One row fixture's decode helper. Every call is built from the wire so
    /// the plan (L) owns all label decisions; this leg only asserts the view
    /// mapping on top of it.
    private func makeRowCall(_ id: String,
                             _ name: String,
                             kind: CodeToolKind,
                             status: String = "done",
                             content: String) -> CodeToolCall? {
        let json = """
        {"id":"\(id)","sessionId":"gate-rows","type":"tool","status":"\(status)","orderSeq":1,
         "content":{"toolName":"\(name)",\(content)},
         "source":{"itemId":"\(id)","nativeMessageId":"gate-rows","blockIndex":0}}
        """
        guard let item = Self.decodeItem(json) else {
            failures.append("collapsedRows: fixture \(id) did not decode")
            return nil
        }
        return CodeToolCall(item: item, kind: kind)
    }

    /// R28 acceptance fixtures: single call, multiple categories (the cap
    /// keeps three, failure first), partial failure, whole failure, diff,
    /// thinking, the SendMessage/session mapping, the empty-summary fallback,
    /// the official icon table and the row heights. The same fixtures feed
    /// the two gallery screenshots (light and dark).
    private func runCollapsedRowFixtures() {
        let read = makeRowCall("row-read", "Read", kind: .read,
                               content: #""input":{"file_path":"/repo/Sources/App.swift"}"#)
        let runningBash = makeRowCall("row-bash-running", "Bash", kind: .bash,
                                      status: "running",
                                      content: #""input":{"command":"swift build"}"#)
        let failedBash = makeRowCall("row-bash-failed", "Bash", kind: .bash,
                                     status: "failed",
                                     content: #""input":{"command":"npm test"}"#)
        let bashA = makeRowCall("row-bash-a", "Bash", kind: .bash,
                                status: "failed", content: #""input":{"command":"ls"}"#)
        let bashB = makeRowCall("row-bash-b", "Bash", kind: .bash,
                                status: "failed", content: #""input":{"command":"pwd"}"#)
        let edit = makeRowCall("row-edit", "Edit", kind: .edit,
                               content: #""input":{"file_path":"/repo/B.swift"}"#)
        let editDiff = makeRowCall(
            "row-edit-diff", "Edit", kind: .edit,
            content: #""input":{"file_path":"/repo/validate-email.ts"},"output":{"lineStat":{"addedLineCount":2,"removedLineCount":1}}"#)
        let task = makeRowCall("row-task", "Task", kind: .task,
                               content: #""input":{"description":"audit the tests"}"#)
        let readA = makeRowCall("row-read-a", "Read", kind: .read, status: "failed",
                                content: #""input":{"file_path":"/repo/A.swift"}"#)
        let readB = makeRowCall("row-read-b", "Read", kind: .read,
                                content: #""input":{"file_path":"/repo/B.swift"}"#)
        // Distinct `content.tool` values keep the span off the shared-target
        // path (which counts the tool name for `.other` calls) so the plan
        // emits the official `sessionMessage` summary phrase.
        let send1 = makeRowCall("row-send-1", "SendMessage", kind: .mcp,
                                content: #""tool":"alpha","input":{"content":"hey"}"#)
        let send2 = makeRowCall("row-send-2", "SendMessage", kind: .mcp,
                                status: "failed",
                                content: #""tool":"beta","input":{"content":"yo"}"#)
        let send3 = makeRowCall("row-send-3", "SendMessage", kind: .mcp,
                                content: #""tool":"gamma","input":{"content":"sup"}"#)
        let web = makeRowCall("row-web", "WebFetch", kind: .search,
                              content: #""input":{"url":"https://example.com"}"#)
        let grep = makeRowCall("row-grep", "Grep", kind: .search,
                               content: #""input":{"pattern":"needle"}"#)
        let writeCreate = makeRowCall(
            "row-write-create", "Write", kind: .write,
            content: #""input":{"file_path":"/repo/New.swift"},"text":"File created successfully at: /repo/New.swift""#)
        let writeUpdate = makeRowCall(
            "row-write-update", "Write", kind: .write,
            content: #""input":{"file_path":"/repo/Old.swift"},"text":"The file /repo/Old.swift has been updated successfully. (file state is current in your context — no need to Read it back)""#)
        let emptyLabel = CodeToolLabels.label(for: [], cwd: nil)

        guard let read, let runningBash, let failedBash, let bashA, let bashB,
              let edit, let editDiff, let task, let readA, let readB,
              let send1, let send2, let send3, let web, let grep,
              let writeCreate, let writeUpdate else { return }

        var fixtures: [[String: Any]] = []

        // 1. Single call: verb `text300` + mono target `text100`.
        let readLabel = CodeToolLabels.label(for: [read], cwd: nil)
        let readRuns = CodeToolLabels.runs(for: readLabel,
                                           differentiateWithoutColor: false)
        let expectedRead = String(localized: "ccr_verb_read")
            + " " + (readLabel.target ?? "")
        check(readRuns.map(\.text).joined() == expectedRead,
              "collapsedRows single: '\(readRuns.map(\.text).joined())', expected '\(expectedRead)'")
        check(readRuns.count == 2
                && readRuns[0].role == .primary
                && readRuns[1].role == .target
                && readRuns[1].face == .mono,
              "collapsedRows single: runs \(readRuns)")
        fixtures.append(["case": "single", "text": expectedRead,
                         "height": Double(36)])

        // 2. Single failed call: both runs `danger00`; with
        // differentiateWithoutColor the colour is replaced by the written
        // suffix and both runs return to their normal roles.
        let failedLabel = CodeToolLabels.label(for: [failedBash], cwd: nil)
        let failedRuns = CodeToolLabels.runs(for: failedLabel,
                                             differentiateWithoutColor: false)
        check(failedRuns.count == 2
                && failedRuns.allSatisfy { $0.role == .failure },
              "collapsedRows failed: runs \(failedRuns)")
        // Literal expectation, not `visibleText(...)`: that helper is defined
        // as the same `runs(...).map(\.text).joined()`, so comparing the two
        // could never fail.
        let expectedFailedText = String(localized: "ccr_verb_ran") + " npm test"
        check(failedRuns.map(\.text).joined() == expectedFailedText,
              "collapsedRows failed: '\(failedRuns.map(\.text).joined())',"
                + " expected '\(expectedFailedText)'")
        let failedWords = CodeToolLabels.runs(for: failedLabel,
                                              differentiateWithoutColor: true)
        check(failedWords.count == 3
                && failedWords[0].role == .primary
                && failedWords[1].role == .target
                && failedWords[2].text == CodeToolLabels.failedSuffix(1),
              "collapsedRows failed: differentiate runs \(failedWords)")
        fixtures.append(["case": "failed",
                         "text": failedRuns.map(\.text).joined()])

        // 3. Partial failure: a category that did not wholly fail keeps
        // `text300` and always carries `ccr_summary_failed_count`.
        let partialLabel = CodeToolLabels.label(for: [readA, readB], cwd: nil)
        let partialRuns = CodeToolLabels.runs(for: partialLabel,
                                              differentiateWithoutColor: true)
        check(partialLabel.phrases.count == 1
                && partialLabel.phrases.first?.failed == 1
                && partialLabel.phrases.first?.whole == false,
              "collapsedRows partial: phrases \(partialLabel.phrases)")
        check(partialRuns.filter { $0.role == .failure }.isEmpty,
              "collapsedRows partial: a non-whole category must not paint red")
        check(partialRuns.last?.text == CodeToolLabels.failedSuffix(1),
              "collapsedRows partial: missing failed suffix in \(partialRuns)")
        fixtures.append(["case": "partial",
                         "text": partialRuns.map(\.text).joined()])

        // 4. Four categories: the plan keeps three, failure first, printed in
        // first-seen order; the wholly failed category is red and carries no
        // suffix when colour is allowed.
        let multiCalls = [read, bashA, bashB, edit, task]
        let multiLabel = CodeToolLabels.label(for: multiCalls, cwd: nil)
        let multiRuns = CodeToolLabels.runs(for: multiLabel,
                                            differentiateWithoutColor: false)
        let multiText = multiRuns.map(\.text).joined()
        let taskText = String(localized: "ccr_summary_task_one")
        check(multiLabel.phrases.count == 3,
              "collapsedRows multi: \(multiLabel.phrases.count) phrases, expected 3")
        check(!multiText.localizedCaseInsensitiveContains(taskText),
              "collapsedRows multi: the dropped task category still rendered (\(multiText))")
        check(multiRuns.filter { $0.role == .failure }.count == 1,
              "collapsedRows multi: exactly the two failed commands are red (\(multiRuns))")
        check(multiRuns.contains { $0.text == CodeToolLabels.phraseSeparator },
              "collapsedRows multi: missing ', ' separator")
        fixtures.append(["case": "multi", "text": multiText,
                         "phrases": multiLabel.phrases.map(\.text)])

        // 5. Diff indicator data. Its own accessibility label text is
        // UNKNOWN (D8), so no row-level value is synthesised.
        let diffLabel = CodeToolLabels.label(for: [editDiff], cwd: nil)
        check(diffLabel.diff == CodeDiffStat(added: 2, removed: 1),
              "collapsedRows diff: \(String(describing: diffLabel.diff))")
        fixtures.append(["case": "diff", "text":
                            CodeToolLabels.runs(for: diffLabel,
                                                differentiateWithoutColor: false)
                                .map(\.text).joined()])

        // 6. SendMessage: the official `sessionMessage` summary, not "Used".
        let sessionLabel = CodeToolLabels.label(for: [send1, send2, send3],
                                                cwd: nil)
        let sessionText = sessionLabel.phrases.first?.text ?? ""
        let expectedSession = String(
            format: String(localized: "ccr_summary_session_message_other"), 3)
        check(sessionLabel.phrases.count == 1 && sessionText == expectedSession,
              "collapsedRows session: '\(sessionText)', expected '\(expectedSession)'")
        check(!sessionText.localizedCaseInsensitiveContains(
                String(localized: "ccr_verb_used")),
              "collapsedRows session: rendered the neutral Used verb (\(sessionText))")
        let sessionRuns = CodeToolLabels.runs(for: sessionLabel,
                                              differentiateWithoutColor: true)
        check(sessionRuns.contains { $0.text == CodeToolLabels.failedSuffix(1) },
              "collapsedRows session: missing failed suffix \(sessionRuns)")

        // 7. Empty summary falls back to `ccr_collapsed_steps_title`.
        let emptyRuns = CodeToolLabels.runs(for: emptyLabel,
                                            differentiateWithoutColor: false)
        check(emptyRuns.map(\.text).joined()
                == String(localized: "ccr_collapsed_steps_title"),
              "collapsedRows empty: '\(emptyRuns.map(\.text).joined())'")

        // 8. The 1023 category → Anthropicon table (R28 §4.1).
        let iconCases: [(String, String)] = [
            (CodeToolLabels.anthropicon(for: read), "anthropicon.eye"),
            (CodeToolLabels.anthropicon(for: edit), "anthropicon.edit"),
            (CodeToolLabels.anthropicon(for: writeCreate), "anthropicon.fileAdd"),
            (CodeToolLabels.anthropicon(for: writeUpdate), "anthropicon.edit"),
            (CodeToolLabels.anthropicon(for: grep), "anthropicon.search"),
            (CodeToolLabels.anthropicon(for: web), "anthropicon.globe"),
            (CodeToolLabels.anthropicon(for: task), "anthropicon.agentSimple"),
            (CodeToolLabels.anthropicon(for: send1), "anthropicon.wrench"),
            (CodeToolLabels.anthropicon(for: [read, bashA]), "anthropicon.listBullet"),
            (CodeToolLabels.anthropicon(for: [edit, edit]), "anthropicon.edit"),
        ]
        for (actual, expected) in iconCases {
            check(actual == expected,
                  "collapsedRows icon: \(actual), expected \(expected)")
        }

        // 9. Row-shape rules from the 1023 row construction: the tool packer
        // (`0x1033b901c`) and the summary direct path (`0x1033b8b20`) both
        // pass a concrete icon into the row init, so the leading icon is
        // never omitted. `TimelineStatusGlyph` is a fixed element of the row
        // body; its non-failure branch is the semibold checkmark and the
        // FailureGlyph branch is the R-A warning glyph. The caret is a 20x20
        // icon box in a 24 pt frame.
        check(CodeCollapsedStepsRow.statusGlyphKind(status: .complete,
                                                    failureExtent: nil) == .checkmark,
              "collapsedRows rule: a settled row lost its checkmark branch")
        check(CodeCollapsedStepsRow.statusGlyphKind(status: .failed,
                                                    failureExtent: nil) == .failure,
              "collapsedRows rule: the failure-glyph branch was removed")
        check(CodeCollapsedStepsRow.statusGlyphKind(status: .complete,
                                                    failureExtent: .partial) == .failure,
              "collapsedRows rule: a partial extent lost the failure branch")
        check(CodeCollapsedStepsRow.statusGlyphKind(status: .running,
                                                    failureExtent: nil) == .none,
              "collapsedRows rule: a running row drew an unproven glyph")
        check(CodePageTheme.toolRowCaretSlotSize == 20
                && CodePageTheme.toolRowCaretFrameHeight == 24,
              "collapsedRows rule: caret slot \(CodePageTheme.toolRowCaretSlotSize)"
                + " frame \(CodePageTheme.toolRowCaretFrameHeight), expected 20/24")

        // 10. Gallery: single / multi / running / failed / diff / thinking /
        // pure text.
        let runningLabel = CodeToolLabels.label(for: [runningBash], cwd: nil)
        check(runningLabel.isRunning,
              "collapsedRows running: the label is not in the running state")
        rowGallery = [
            CodeCollapsedRowFixture(id: "g-single", kind: .tool,
                                    label: readLabel, icon: "anthropicon.eye",
                                    status: .complete, failureExtent: nil,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-running", kind: .tool,
                                    label: runningLabel,
                                    icon: "anthropicon.commandLinePrompt",
                                    status: .running, failureExtent: nil,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-multi", kind: .tool,
                                    label: multiLabel, icon: "anthropicon.listBullet",
                                    status: .complete, failureExtent: .partial,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-failed", kind: .tool,
                                    label: failedLabel, icon: "anthropicon.commandLinePrompt",
                                    status: .failed, failureExtent: .failed,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-diff", kind: .tool,
                                    label: diffLabel, icon: "anthropicon.edit",
                                    status: .complete, failureExtent: nil,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-thinking", kind: .thinking,
                                    label: CodeToolRowLabel(verb: "", isRunning: false),
                                    icon: "anthropicon.extendedThinking",
                                    status: .complete, failureExtent: nil,
                                    hasDetails: true),
            CodeCollapsedRowFixture(id: "g-text", kind: .tool,
                                    label: emptyLabel, icon: nil,
                                    status: .complete, failureExtent: nil,
                                    hasDetails: false),
        ]

        // D8 is still UNKNOWN: the row has no direct accessibility-label call
        // (Button automatic label). Record the visible text the automatic
        // label reads, so a VoiceOver Inspector pass can compare against it.
        let autoLabels = rowGallery.map { item -> [String: String] in
            switch item.kind {
            case .thinking:
                return ["id": item.id,
                        "text": String(localized: "thought_process")]
            case .tool:
                return ["id": item.id,
                        "text": CodeToolLabels.visibleText(
                            for: item.label, differentiateWithoutColor: false)]
            }
        }

        // 11. Detail thinking Typography (E, R28 §U 收口三): the thinking
        // `MarkdownText` leaf is 15.0 / weight 400 / lineHeight 21.0 relative
        // `.body` (`0x100b6a998`; constants `0x100b6ab48` / `0x100b6abc8` /
        // `0x100b6ac5c`), paragraph spacing = body size. The line spacing is
        // the delta over the real face's natural line box, so these pin the
        // scale while the font swap below cannot silently move it.
        let thinkingScale = CodePageTheme.thinkingMarkdownScale
        check(thinkingScale.body == 15,
              "collapsedRows thinking: body \(thinkingScale.body), expected 15")
        check(thinkingScale.lineSpacing == 21 - CodePageTheme.toolRowSansFont.lineHeight,
              "collapsedRows thinking: line spacing \(thinkingScale.lineSpacing),"
                + " expected 21 − \(CodePageTheme.toolRowSansFont.lineHeight)")
        check(thinkingScale.paragraphSpacing == 15,
              "collapsedRows thinking: paragraph spacing"
                + " \(thinkingScale.paragraphSpacing), expected 15")

        report["collapsedRows"] = [
            "fixtures": fixtures,
            "iconCases": iconCases.map { ["actual": $0.0, "expected": $0.1] },
            "gallery": rowGallery.map(\.id),
            "autoLabels": autoLabels,
            "thinkingTypography": [
                "body": Double(thinkingScale.body),
                "lineSpacing": Double(thinkingScale.lineSpacing),
                "paragraphSpacing": Double(thinkingScale.paragraphSpacing),
            ],
        ] as [String: Any]
    }

    // MARK: - Views and screenshots

    private func captureViews() async {
        prepareViews()
        await verifyMessageRowHeight()
        await verifyRowHeights()
        await verifyReadOutputHeight()
        await verifyCollapsedRowHeights()
        await verifyRendererMeasure()
        await verifyRealCollectionFirstFit()

        var views: [String: Any] = [:]

        if messageGroup != nil {
            stage = .messageRow
            // ChatMarkdownView parses its body off the main thread in a
            // `.task`; give the short fixture time to land before the capture.
            await wait(1200)
            views["messageRow"] = capture("code-message-row.png")
        } else {
            failures.append("views: message row fixture unavailable")
        }
        report["views"] = views
        persist(phase: "views.messageRow")

        if detailCall != nil {
            stage = .detail
            await wait(600)
            // The Read body is 298 lines: the middle band must contain real
            // dark glyphs, not just the card header. This is the pixel check
            // the height-only assertion could not provide.
            views["detail"] = capture(
                "code-detail.png",
                check: CapturePixelCheck(ink: .dark,
                                         inkBand: 0.52...0.92,
                                         minimumInkPixels: 500))
        } else {
            failures.append("views: tool detail fixture unavailable")
        }
        report["views"] = views
        persist(phase: "views.detail")

        if !detailGroupCalls.isEmpty {
            stage = .detailGroup
            await wait(600)
            // The group page starts with the thinking block, then the call
            // list. The band's lower bound was 0.25, which starts below the
            // thinking text: a page whose thinking block had not laid out yet
            // (or a short call list) left the sampled band nearly empty and
            // failed a correct capture. 0.10 reaches the first paragraph
            // while `minimumInkPixels` still catches a blank page.
            views["detailGroup"] = capture(
                "code-detail-group.png",
                check: CapturePixelCheck(ink: .dark,
                                         inkBand: 0.10...0.90,
                                         minimumInkPixels: 200))
        } else {
            failures.append("views: detail group fixture unavailable")
        }
        report["views"] = views
        persist(phase: "views.detailGroup")

        stage = .workingMark
        await wait(500)
        views["workingMark"] = capture("code-working-mark.png")
        report["views"] = views
        persist(phase: "views.workingMark")

        // The three live working-row texts: the ≥60 s thinking tier, the
        // closed `思考了 X`, and the rotating-verb fallback. The stage lays
        // them out around the vertical centre: the blank-capture detector
        // samples the middle band, and a top-aligned stack left that band
        // empty (2026-10-25 run 40205262431).
        stage = .thinkingStatus
        await wait(500)
        views["thinkingStatus"] = capture("code-thinking-status.png")
        report["views"] = views
        persist(phase: "views.thinkingStatus")

        // The return control over the same Code row: this is the only capture
        // that shows its glass circle, icon and leading margin, so a reviewer
        // can check the placement before the device build.
        if messageGroup != nil {
            stage = .scrollDown
            await wait(500)
            views["scrollDown"] = capture("code-scroll-down.png")
            report["views"] = views
            persist(phase: "views.scrollDown")
        }

        // The R28 collapsed-row gallery, once light and once dark. The dark
        // stage is the same view tree under `.preferredColorScheme(.dark)`,
        // so a reviewer can diff every token pair on one page.
        if !rowGallery.isEmpty {
            stage = .collapsedRows
            await wait(500)
            views["collapsedRows"] = capture(
                "code-collapsed-rows.png",
                check: CapturePixelCheck(background: .light))
            report["views"] = views
            persist(phase: "views.collapsedRows")

            stage = .collapsedRowsDark
            await wait(500)
            // Dark tokens must really be dark: the page background is
            // #151515 and the row ink is the light pair (text100 dark is
            // (249,249,247)). A background-only swap leaves no bright ink.
            views["collapsedRowsDark"] = capture(
                "code-collapsed-rows-dark.png",
                check: CapturePixelCheck(background: .dark,
                                         ink: .bright,
                                         inkBand: 0.25...0.95,
                                         minimumInkPixels: 300,
                                         minimumTargetPixels: 50))
            report["views"] = views
            persist(phase: "views.collapsedRowsDark")
        } else {
            failures.append("views: collapsed-row gallery unavailable")
        }
    }

    /// Hosts every gallery fixture at the default and AX3 sizes and asserts
    /// the R28 heights: 36 pt (24 pt slot + 12 pt padding) with an icon or
    /// caret, 33 pt (21 pt text line + 12) for pure text. AX3 must be taller
    /// than default (the row text is `relative(.body)`), never clipped.
    private func verifyCollapsedRowHeights() async {
        guard let window = keyWindow else {
            failures.append("collapsedRows height: no key window")
            return
        }
        guard !rowGallery.isEmpty else {
            failures.append("collapsedRows height: gallery is empty")
            return
        }
        let width: CGFloat = 361
        var cases: [[String: Any]] = []
        for item in rowGallery {
            let regular = measureCollapsedRow(item, width: width,
                                              category: .large, window: window)
            let accessibility = measureCollapsedRow(
                item, width: width,
                category: .accessibilityExtraLarge, window: window)
            let expected = item.expectedDefaultHeight
            let pass = abs(regular - expected) <= 0.5
            check(pass, "collapsedRows height \(item.id): \(regular) pt,"
                    + " expected \(expected)")
            check(accessibility > regular,
                  "collapsedRows height \(item.id): AX3 \(accessibility) pt"
                    + " is not taller than default \(regular) pt")
            cases.append(["id": item.id,
                          "expected": Double(expected),
                          "regular": Double(regular),
                          "accessibility3": Double(accessibility),
                          "passed": pass])
            print("collapsedRowHeight \(item.id) expected=\(expected)"
                + " regular=\(regular) ax3=\(accessibility) pass=\(pass)")
        }
        report["collapsedRowHeights"] = [
            "width": Double(width),
            "cases": cases,
        ] as [String: Any]
        persist(phase: "views.collapsedRowHeights")
    }

    private func measureCollapsedRow(_ item: CodeCollapsedRowFixture,
                                     width: CGFloat,
                                     category: UIContentSizeCategory,
                                     window: UIWindow) -> CGFloat {
        let host = UIHostingController(rootView:
            AnyView(item.rowView()
                .frame(width: width)
                .ignoresSafeArea()))
        host.view.backgroundColor = .clear
        host.traitOverrides.preferredContentSizeCategory = category
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        window.addSubview(host.view)
        host.view.layoutIfNeeded()
        let safeTop = host.view.safeAreaInsets.top
        let safeBottom = host.view.safeAreaInsets.bottom
        let raw = host.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        host.view.removeFromSuperview()
        return max(0, raw - safeTop - safeBottom)
    }

    private func prepareViews() {
        guard !didPrepareViews else { return }
        didPrepareViews = true

        // Pure-constant assertions run before the fixtures so a broken
        // fixture cannot hide a token regression.
        verifyGroupDetailEvidence()

        guard let items = Self.decodeItems(Self.viewFixtureJSON) else {
            failures.append("views: fixture JSON did not decode")
            return
        }
        let builderRows = CodeMessageBuilder.rows(for: items, profile: .claudeCode)
        check(builderRows.count == 2,
              "views: \(builderRows.count) message rows, expected the user row and the assistant row")
        check(builderRows.first?.role == .user,
              "views: the first message row is not the user row")
        check(builderRows.last?.role == .assistant,
              "views: the second message row is not the assistant row")

        // Settled-only thinking: the persistent fixture carries one done
        // reasoning block; a running reasoning row must vanish entirely
        // (the 2026-10-28 regression that made `思考过程` flicker).
        let persistedReasoning = builderRows.flatMap(\.blocks).filter { block in
            if case .reasoning = block { return true }
            return false
        }
        check(persistedReasoning.count == 1,
              "views: \(persistedReasoning.count) persistent reasoning blocks, expected the settled one")
        if let runningItems = Self.decodeItems(Self.runningReasoningJSON) {
            let runningRows = CodeMessageBuilder.rows(for: runningItems,
                                                      profile: .claudeCode)
            let hasRunningReasoning = runningRows.flatMap(\.blocks).contains { block in
                if case .reasoning = block { return true }
                return false
            }
            check(!hasRunningReasoning,
                  "views: a running reasoning row produced a persistent block")
        } else {
            failures.append("views: running reasoning fixture did not decode")
        }

        let rows = items.map { ChatTimelineRowModel($0) }
        messageGroup = ChatTimelineGroup(kind: .single, rows: rows,
                                         explicitID: "gate-code-thread")

        // Layer 2: the single-call page, using the long Read output that
        // rendered as a blank card on the b643 device.
        let readText = Self.longReadOutputText
        guard let detailItem = Self.decodeItem(Self.detailCallJSON(output: readText)) else {
            failures.append("views: detail call JSON did not decode")
            return
        }
        detailCall = CodeToolCall(item: detailItem, kind: .read)
        let detailOutput = CodeToolOutput(item: detailItem, kind: .read)
        if case let .text(text) = detailOutput {
            check(text.count == readText.count,
                  "views: detail Read output \(text.count) chars, expected \(readText.count)")
        } else {
            failures.append("views: detail call parsed as \(Self.describe(detailOutput)), expected text")
        }

        // Layer 1: the span summary page. Three edits to two files must
        // summarize as "Edited 2 files", list all three calls, and every
        // listed call must have input (and one a diff output).
        //
        // The fixture is a real message group (one settled reasoning row plus
        // the three tool rows) decoded through `CodeMessageBuilder`, so the
        // page's calls come from the same builder the transcript uses. The
        // reasoning row must not leak into the page: the group detail carries
        // the call list only (pp device report 2026-10-29).
        guard let groupItems = Self.decodeItems(Self.detailGroupJSON) else {
            failures.append("views: detail group fixture JSON did not decode")
            return
        }
        let groupRows = CodeMessageBuilder.rows(for: groupItems, profile: .claudeCode)
        let groupBlocks = groupRows.first?.blocks ?? []
        detailGroupCalls = groupBlocks.flatMap { block -> [CodeToolCall] in
            guard case let .toolCalls(segments) = block else { return [] }
            return segments.flatMap { CodeToolLabels.calls(in: $0) }
        }
        check(detailGroupCalls.count == 3,
              "views: detail group has \(detailGroupCalls.count) calls, expected 3")
        let groupLabel = CodeToolLabels.label(for: detailGroupCalls, cwd: "/repo")
        check(groupLabel.phrases.count == 1 && groupLabel.phrases.first?.total == 2,
              "views: detail group phrases \(groupLabel.phrases), expected one 2-file phrase")
        let groupTitle = CodeToolLabels.visibleText(
            for: groupLabel, differentiateWithoutColor: false)
        let expectedGroupTitle = String(
            format: String(localized: "ccr_summary_edit_other"), 2)
        check(groupTitle == expectedGroupTitle,
              "views: detail group title '\(groupTitle)', expected '\(expectedGroupTitle)'")
        check(detailGroupCalls.allSatisfy {
                  CodeToolCallDetailView.inputText(for: $0) != nil
              },
              "views: a detail group call has no input for its pushed page")
        let groupOutputs = detailGroupCalls.map {
            CodeToolOutput(item: $0.item, kind: $0.kind)
        }
        check(groupOutputs.contains { !$0.isEmpty },
              "views: no detail group call renders output")
        report["detailGroup"] = [
            "title": groupTitle,
            "rows": detailGroupCalls.count,
            "outputs": groupOutputs.map { $0.isEmpty ? "none" : "present" },
        ] as [String: Any]
    }

    /// The R-A/R-D/R-E/R-F constants the group detail and status glyph now
    /// draw with. Each value is asserted against its evidence:
    /// - FailureGlyph: asset name, `16 + 4 × raw` frame, failed/partial sRGB
    ///   pairs (R-A E4/E5/E6/E7);
    /// - group chevron `textMuted` (R-F C5/C7) and the collapsed caret's
    ///   unchanged `text400` (R-F C8);
    /// - `PlainListRowInsets` `(0, 24, 0, 24)` (R-D §2);
    /// - connector 2 pt / 24 pt column / 8 pt gap / light+dark ink
    ///   (R-E C3/C5).
    private func verifyGroupDetailEvidence() {
        check(CodePageTheme.failureGlyphAssetName == "anthropicon.warning",
              "groupDetail glyph: asset '\(CodePageTheme.failureGlyphAssetName)',"
                + " expected 'anthropicon.warning'")
        check(UIImage(named: CodePageTheme.failureGlyphAssetName) != nil,
              "groupDetail glyph: asset"
                + " '\(CodePageTheme.failureGlyphAssetName)' is not in the bundle")
        check(CodePageTheme.failureGlyphSize == .medium,
              "groupDetail glyph: default size U changed from .medium")
        for size in AnthropiconSize.allCases {
            let expected = 16 + 4 * CGFloat(size.rawValue)
            check(CodePageTheme.failureGlyphFrameSide(for: size) == expected,
                  "groupDetail glyph: frame side for \(size) is"
                    + " \(CodePageTheme.failureGlyphFrameSide(for: size)),"
                    + " expected \(expected)")
        }
        for (rawSize, expected) in [16, 20, 24, 28, 32].enumerated() {
            check(CodePageTheme.failureGlyphFrameSide(rawSize: rawSize)
                    == CGFloat(expected),
                  "groupDetail glyph: raw \(rawSize) side is"
                    + " \(CodePageTheme.failureGlyphFrameSide(rawSize: rawSize)),"
                    + " expected \(expected)")
        }
        check(CodePageTheme.failureGlyphFrameSide(for: .small) == 16
                && CodePageTheme.failureGlyphFrameSide(for: .medium) == 20
                && CodePageTheme.failureGlyphFrameSide(for: .large) == 24,
              "groupDetail glyph: the 16/20/24 size table moved")
        assertSRGB(CodePageTheme.failureGlyphFailedColor,
                   light: (0.557, 0.149, 0.149),
                   dark: (0.925, 0.494, 0.494),
                   alpha: 1, label: "groupDetail glyph failed")
        assertSRGB(CodePageTheme.failureGlyphPartialColor,
                   light: (0.451, 0.271, 0),
                   dark: (0.859, 0.576, 0),
                   alpha: 1, label: "groupDetail glyph partial")

        check(CodePageTheme.groupListRowInsets == EdgeInsets(top: 0, leading: 24,
                                                             bottom: 0, trailing: 24),
              "groupDetail list: insets \(CodePageTheme.groupListRowInsets),"
                + " expected (0,24,0,24)")
        assertSRGB(CodePageTheme.textMutedColor,
                   light: (0.537, 0.529, 0.506),
                   dark: (0.537, 0.529, 0.506),
                   alpha: 1, label: "groupDetail chevron textMuted")
        // R-F C8: the collapsed caret keeps its own token; a shared constant
        // would silently repaint one of the two surfaces.
        assertSRGB(CodePageTheme.text400Color,
                   light: (0.482, 0.475, 0.455),
                   dark: (0.592, 0.584, 0.553),
                   alpha: 1, label: "collapsed caret text400")

        check(CodePageTheme.timelineConnectorWidth == 2
                && CodePageTheme.timelineConnectorColumnWidth == 24
                && CodePageTheme.timelineConnectorTopGap == 8,
              "groupDetail connector: geometry"
                + " \(CodePageTheme.timelineConnectorWidth)/"
                + "\(CodePageTheme.timelineConnectorColumnWidth)/"
                + "\(CodePageTheme.timelineConnectorTopGap), expected 2/24/8")
        assertSRGB(CodePageTheme.timelineConnectorColor,
                   light: (0.043, 0.043, 0.043),
                   dark: (1, 1, 1),
                   alpha: 0.1, label: "groupDetail connector")

        report["groupDetailEvidence"] = [
            "failureGlyphAsset": CodePageTheme.failureGlyphAssetName,
            "failureGlyphSize": "\(CodePageTheme.failureGlyphSize)",
            "failureGlyphFrameSides": AnthropiconSize.allCases.map {
                Double(CodePageTheme.failureGlyphFrameSide(for: $0))
            },
            "rowInsets": [
                Double(CodePageTheme.groupListRowInsets.top),
                Double(CodePageTheme.groupListRowInsets.leading),
                Double(CodePageTheme.groupListRowInsets.bottom),
                Double(CodePageTheme.groupListRowInsets.trailing),
            ],
            "connector": [
                Double(CodePageTheme.timelineConnectorWidth),
                Double(CodePageTheme.timelineConnectorColumnWidth),
                Double(CodePageTheme.timelineConnectorTopGap),
            ],
        ] as [String: Any]
    }

    /// Resolves a `SchemeColor` through its dynamic `UIColor` and compares
    /// the four components under each appearance. This asserts the colour
    /// that reaches the screen, not a duplicated literal.
    private func assertSRGB(_ color: CodePageTheme.SchemeColor,
                            light: (CGFloat, CGFloat, CGFloat),
                            dark: (CGFloat, CGFloat, CGFloat),
                            alpha: CGFloat,
                            label: String) {
        let cases: [(String, UIUserInterfaceStyle, (CGFloat, CGFloat, CGFloat))] = [
            ("light", .light, light),
            ("dark", .dark, dark),
        ]
        for (appearance, style, expected) in cases {
            let resolved = CodePageTheme.uiColor(color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var resolvedAlpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green,
                                  blue: &blue, alpha: &resolvedAlpha) else {
                failures.append("\(label) \(appearance): getRed failed")
                continue
            }
            // 1/255 ≈ 0.0039: a colour-space round trip must not turn a
            // correct token red, while the closest expected pair (failed
            // dark R 0.925 vs danger00 dark R 0.957) still separates.
            let tolerance: CGFloat = 0.005
            check(abs(red - expected.0) <= tolerance
                    && abs(green - expected.1) <= tolerance
                    && abs(blue - expected.2) <= tolerance
                    && abs(resolvedAlpha - alpha) <= tolerance,
                  "\(label) \(appearance): (\(red), \(green), \(blue),"
                    + " \(resolvedAlpha)), expected \(expected) @\(alpha)")
        }
    }

    /// The exact height the controller stores before apply must equal the
    /// height the hosting row actually lays out at, or the row will correct
    /// itself when it first becomes visible — the movement the device probe
    /// caught. Render the same fixture offscreen, wait for ChatMarkdownView's
    /// parse, and compare.
    private func verifyMessageRowHeight() async {
        guard let group = messageGroup, let window = keyWindow else { return }
        let rowWidth = window.bounds.width - 2 * CodePageTheme.rowMarginLeading
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: String(describing: DynamicTypeSize.large),
            layoutDirection: 0,
            boldText: false,
            scale: CodePageTheme.markdownScale)
        let host = UIHostingController(rootView:
            CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo",
                               typography: typography)
                .padding(.horizontal, CodePageTheme.rowMarginLeading)
                // `sizeThatFits` includes the hosting window's safe area; the
                // row itself is laid out below the status bar in the timeline.
                // The parity gate hit the same 68 pt inset in the M1 spike.
                .ignoresSafeArea())
        host.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 200)
        host.view.backgroundColor = .clear
        window.addSubview(host.view)
        host.view.layoutIfNeeded()
        // `ChatMarkdownView` parses its body in a task; the task only runs once
        // the view is in a window.
        await wait(1200)
        host.view.layoutIfNeeded()
        let inWindow = host.sizeThatFits(in: CGSize(
            width: window.bounds.width, height: .greatestFiniteMagnitude)).height
        let safeTop = host.view.safeAreaInsets.top
        let safeBottom = host.view.safeAreaInsets.bottom
        let traits = host.traitCollection
        // `sizeThatFits` keeps the window's safe-area insets even with
        // `.ignoresSafeArea()` on the content. Measure the same parsed view
        // off the window and subtract the insets captured in the window: the
        // row inside the timeline has no status-bar/home-indicator space.
        host.view.removeFromSuperview()
        host.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 200)
        host.view.layoutIfNeeded()
        let rendered = max(0, host.sizeThatFits(in: CGSize(
            width: window.bounds.width, height: .greatestFiniteMagnitude)).height
            - safeTop - safeBottom)

        let measured = CodeMessageHeightMeasurer.height(
            group: group, profile: .claudeCode,
            width: rowWidth, typography: typography, traits: traits, measured: true)
        let delta = abs(measured - rendered)
        // Three points covers the Textual/TextKit parity gap measured on the
        // shared fixture (~1.7 pt); anything larger is a structural mistake.
        check(delta <= 3,
              "views: message row measured \(measured) pt, rendered \(rendered) pt (delta \(delta)); the pre-apply height disagrees with the row")
        report["messageRowHeight"] = [
            "measured": Double(measured),
            "rendered": Double(rendered),
            "inWindow": Double(inWindow),
            "safeTop": Double(safeTop),
            "safeBottom": Double(safeBottom),
            "delta": Double(delta),
        ]
    }

    // MARK: - Row-height matrix (official height contract)

    /// One measured row-height case: the same `CodeMessageRowView` the Code
    /// page installs, offscreen at a chosen content width and Dynamic Type,
    /// compared with `CodeMessageHeightMeasurer` — the value the adapter
    /// stores before apply. A delta beyond the class threshold means the row
    /// corrects its height when it first becomes visible (the movement the
    /// device probe caught).
    private struct RowHeightFixture {
        enum Kind: String {
            case text
            case bubble
            case tool

            /// Text and the user bubble must match the renderer within 1 pt;
            /// the pure-tool arithmetic is allowed 2 pt.
            var threshold: CGFloat {
                switch self {
                case .tool: return 2
                // The Textual InlineText line metrics differ from TextKit by
                // ~1.4 pt on five CJK lines; the cell self-measure is exact,
                // so this is an estimate tolerance, not a row-height tolerance.
                case .bubble: return 2
                case .text: return 1
                }
            }
        }

        struct Size {
            let name: String
            let dynamicType: DynamicTypeSize
            let category: UIContentSizeCategory

            static let regular = Size(name: "large",
                                      dynamicType: .large,
                                      category: .large)
            static let accessibility = Size(name: "accessibility3",
                                            dynamicType: .accessibility3,
                                            category: .accessibilityExtraLarge)
        }

        let name: String
        let kind: Kind
        let json: String
        let widths: [CGFloat]
        let sizes: [Size]
    }

    private static let rowHeightFixtures: [RowHeightFixture] = [
        // One collapsed tool segment.
        RowHeightFixture(name: "tool-one", kind: .tool,
                         json: RowHeightFixtureJSON.toolOne,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // Three segments: a span, the Workflow special, then a second span.
        RowHeightFixture(name: "tool-three", kind: .tool,
                         json: RowHeightFixtureJSON.toolThree,
                         widths: [361, 320],
                         sizes: [.regular]),
        // Long CJK with hard line breaks (two trailing spaces + newline).
        RowHeightFixture(name: "cjk-hard-break", kind: .text,
                         json: RowHeightFixtureJSON.cjk,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // Emoji clusters and flags with hard line breaks.
        RowHeightFixture(name: "emoji-hard-break", kind: .text,
                         json: RowHeightFixtureJSON.emoji,
                         widths: [361, 320],
                         sizes: [.regular]),
        // The user bubble, long CJK + emoji.
        RowHeightFixture(name: "bubble-cjk", kind: .bubble,
                         json: RowHeightFixtureJSON.bubble,
                         widths: [361, 320],
                         sizes: [.regular]),
        // Text bubble followed by the image grid and the file grid. The
        // attachments are sibling blocks outside the bubble, and the two
        // grids pay one block gap each (CLOSURE.md §4).
        RowHeightFixture(name: "bubble-attachment", kind: .bubble,
                         json: RowHeightFixtureJSON.bubbleAttachment,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // A pure-attachment message draws no bubble; the image grid is the
        // row's only block.
        RowHeightFixture(name: "bubble-pure-attachment", kind: .bubble,
                         json: RowHeightFixtureJSON.bubblePureAttachment,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // A pure file message: the official 140 pt square card, no bubble.
        RowHeightFixture(name: "bubble-file-only", kind: .bubble,
                         json: RowHeightFixtureJSON.bubbleFileOnly,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // Three images: wide + two squares, two square rows tall.
        RowHeightFixture(name: "bubble-three-images", kind: .bubble,
                         json: RowHeightFixtureJSON.bubbleThreeImages,
                         widths: [361, 320],
                         sizes: [.regular]),
        // Five images: the fourth square carries `+1`.
        RowHeightFixture(name: "bubble-five-images", kind: .bubble,
                         json: RowHeightFixtureJSON.bubbleFiveImages,
                         widths: [361, 320],
                         sizes: [.regular]),
        // Two text bodies plus a collapsed tool call in one message: the
        // builder emits text, text, toolCalls, so the row pays two inter-block
        // gaps and one scaled tool line box.
        RowHeightFixture(name: "multi-block", kind: .text,
                         json: RowHeightFixtureJSON.multiBlock,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // A fenced code block at the default and an accessibility text size:
        // the official header is a ScaledMetric, so the measured and rendered
        // card must grow together instead of clipping the title.
        RowHeightFixture(name: "code-card", kind: .text,
                         json: RowHeightFixtureJSON.codeCard,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
        // A settled thinking row followed by the answer: the measurer's
        // `.thinking` line box and `CodeThinkingRow` must agree at both text
        // sizes (icon 16 / label 15 / minHeight 24 / padding 6).
        RowHeightFixture(name: "thinking", kind: .text,
                         json: RowHeightFixtureJSON.thinking,
                         widths: [361, 320],
                         sizes: [.regular, .accessibility]),
    ]

    /// The 24K / ~298-line Read output that rendered as a blank card on the
    /// device (2026-10-25). The dedicated Read reader draws every line, so a
    /// settled height of a few hundred points means the body vanished again.
    private func verifyReadOutputHeight() async {
        guard let window = keyWindow else {
            failures.append("readOutput: no key window")
            return
        }
        let text = Self.longReadOutputText
        let hostWidth = window.bounds.width
        let host = UIHostingController(rootView:
            CodeToolOutputView(output: .text(text), kind: .read)
                .padding(16)
                .frame(width: hostWidth, alignment: .leading)
                .ignoresSafeArea())
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: hostWidth, height: 200)
        window.addSubview(host.view)
        host.view.layoutIfNeeded()

        let proposed = CGSize(width: hostWidth, height: .greatestFiniteMagnitude)
        var settled = host.sizeThatFits(in: proposed).height
        var previous: CGFloat = -1
        for _ in 0..<20 {
            await wait(100)
            host.view.layoutIfNeeded()
            settled = host.sizeThatFits(in: proposed).height
            if settled > 1, abs(settled - previous) <= 0.5 { break }
            previous = settled
        }
        // The height alone cannot tell a drawn body from the b643 blank card
        // (SwiftUI's `Text` reported the right height and drew nothing). The
        // Read reader is a `UITextView` (TextKit) that carries the whole
        // string; require that view in the hosted tree and that it holds every
        // character. Swapping the reader back to a SwiftUI `Text` removes the
        // text view and turns this assertion red.
        let readTextViews = descendantTextViews(in: host.view)
        let bodyTextView = readTextViews.first { $0.textStorage.length == text.count }
        host.view.removeFromSuperview()

        let finite = settled.isFinite
        check(finite && settled > 2_000,
              "readOutput: \(text.count) chars / 298 lines rendered \(settled) pt, expected a drawn body")
        let readTextViewLengths = readTextViews.map { $0.textStorage.length }
        check(bodyTextView != nil,
              "readOutput: no UITextView carries the \(text.count)-char body"
                + " (text views: \(readTextViewLengths))")
        report["readOutput"] = [
            "characters": text.count,
            "lines": 298,
            "height": Double(settled),
            "finite": finite,
            "textViews": readTextViews.count,
            "textViewLengths": readTextViewLengths,
        ] as [String: Any]
    }

    /// Every `UITextView` below `view`. The Code page's TextKit renderers (the
    /// Read body and the thinking Markdown leaf) are the only text views it
    /// mounts, so a host with none has fallen back to a non-TextKit renderer.
    private func descendantTextViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        func walk(_ current: UIView) {
            if let textView = current as? UITextView { result.append(textView) }
            for subview in current.subviews { walk(subview) }
        }
        walk(view)
        return result
    }

    /// Renders every fixture at every requested width and size, reports each
    /// measured/rendered/delta, and fails past the class threshold. The CI job
    /// re-checks the same table independently.
    private func verifyRowHeights() async {
        guard let window = keyWindow else {
            failures.append("rowHeights: no key window")
            return
        }
        var cases: [[String: Any]] = []
        var expected = 0
        for fixture in Self.rowHeightFixtures {
            guard let items = Self.decodeItems(fixture.json) else {
                failures.append("rowHeights \(fixture.name): fixture JSON did not decode")
                continue
            }
            let group = ChatTimelineGroup(kind: .single,
                rows: items.map { ChatTimelineRowModel($0) },
                explicitID: "gate-height-\(fixture.name)")
            let built = CodeMessageBuilder.rows(for: items, profile: .claudeCode)
            let components = built.map { row -> [String: Any] in
                ["id": row.id,
                 "role": row.role.rawValue,
                 "blocks": Self.blockDescriptors(row.blocks)]
            }
            // `CodeMessageHeightMeasurer` exposes no per-block breakdown, so
            // the component line reports the builder's rows and blocks — the
            // parts both the measurer and the rendered view consume.
            let componentText = built.map { row in
                "\(row.role.rawValue):" + Self.blockDescriptors(row.blocks).joined(separator: ",")
            }.joined(separator: " | ")
            for width in fixture.widths {
                for size in fixture.sizes {
                    expected += 1
                    var record = await measureRowHeight(group: group, fixture: fixture,
                                                        width: width, size: size,
                                                        window: window)
                    let threshold = Double(fixture.kind.threshold)
                    let delta = record["delta"] as? Double ?? .greatestFiniteMagnitude
                    let measuredValue = record["measured"] as? Double ?? -1
                    let renderedValue = record["rendered"] as? Double ?? -1
                    record["fixture"] = fixture.name
                    record["class"] = fixture.kind.rawValue
                    record["width"] = Double(width)
                    record["dynamicType"] = size.name
                    record["threshold"] = threshold
                    record["passed"] = delta <= threshold
                    record["components"] = components
                    record["componentText"] = componentText
                    cases.append(record)
                    check(delta <= threshold,
                          "rowHeights \(fixture.name) [\(fixture.kind.rawValue)]"
                            + " width \(Int(width)) type \(size.name): measured"
                            + " \(measuredValue) rendered \(renderedValue)"
                            + " delta \(delta) > \(threshold)")
                    // The CI log carries the per-case table even when the JSON
                    // artifact is the only thing a later reader has.
                    print("rowHeight \(fixture.name) [\(fixture.kind.rawValue)]"
                        + " width=\(Int(width)) type=\(size.name)"
                        + " measured=\(measuredValue) rendered=\(renderedValue)"
                        + " delta=\(delta) threshold=\(threshold)"
                        + " components=\(componentText)")
                }
            }
        }
        if cases.isEmpty || cases.count != expected {
            failures.append("rowHeights: \(cases.count) cases, expected \(expected)")
        }
        report["rowHeights"] = [
            "thresholds": ["text": 1.0, "bubble": 2.0, "tool": 2.0],
            "widths": [361.0, 320.0],
            "fixtureCount": Self.rowHeightFixtures.count,
            "caseCount": cases.count,
            "expectedCaseCount": expected,
            "componentSource": "CodeMessageBuilder.rows; the measurer exposes no per-block breakdown",
            "cases": cases,
        ] as [String: Any]
        persist(phase: "views.rowHeights")
    }

    // MARK: - Renderer measurement experiment (3 pt / 1900 pt)

    /// Fixtures for the renderer-measurement leg. They stay independent of
    /// `rowHeightFixtures`: that matrix owns the product thresholds, while this
    /// leg only records whether a renderer-only measurement matches the
    /// settled in-window render. A short body, the long CJK body and a body
    /// with a fenced code block plus a table cover the three layout paths.
    private static let rendererMeasureFixtures: [RowHeightFixture] = [
        RowHeightFixture(name: "short", kind: .text,
                         json: RendererMeasureFixtureJSON.short,
                         widths: [361], sizes: [.regular]),
        RowHeightFixture(name: "cjk-hard-break", kind: .text,
                         json: RowHeightFixtureJSON.cjk,
                         widths: [361], sizes: [.regular]),
        RowHeightFixture(name: "code-table", kind: .text,
                         json: RendererMeasureFixtureJSON.codeTable,
                         widths: [361], sizes: [.regular]),
    ]

    /// One Code row measured four ways at one width and Dynamic Type.
    ///
    /// `rendered` is the settled in-window host the existing matrix already
    /// trusts. `hostless` is the `TimelineHostingHeightMeasurer` shape: an
    /// offscreen `UIHostingController` fed the production `preparedBlocks`.
    /// `cellSuper` and `cellForced` are a fresh `TimelineHostingCell` in the
    /// key window fitting itself without a seed; `cellForced` gives the
    /// content view a layout pass first, and `cellSettled` lets the hosted
    /// content commit for 300 ms before the fit. Deltas are recorded, never
    /// asserted — the main session decides which renderer source the product
    /// can trust.
    private func verifyRendererMeasure() async {
        guard let window = keyWindow else {
            failures.append("rendererMeasure: no key window")
            return
        }
        let margin = CodePageTheme.rowMarginLeading
        var cases: [[String: Any]] = []
        var hostlessMaxDelta: Double = 0
        var cellSuperMaxDelta: Double = 0
        var cellForcedMaxDelta: Double = 0
        var cellSettledMaxDelta: Double = 0
        var contentSettledMaxDelta: Double = 0

        for fixture in Self.rendererMeasureFixtures {
            guard let items = Self.decodeItems(fixture.json) else {
                failures.append("rendererMeasure \(fixture.name): fixture JSON did not decode")
                continue
            }
            let group = ChatTimelineGroup(kind: .single,
                rows: items.map { ChatTimelineRowModel($0) },
                explicitID: "gate-renderer-\(fixture.name)")
            guard let width = fixture.widths.first,
                  let size = fixture.sizes.first else {
                failures.append("rendererMeasure \(fixture.name): fixture has no width or size")
                continue
            }
            let hostWidth = width + 2 * margin

            // The adapter's `preparedTextBlocks` rule: one parse per non-user
            // `.text` block, keyed by the text the row will draw. This is the
            // exact input the production `CodeMessageRowView` receives.
            let builtRows = CodeMessageBuilder.rows(for: items, profile: .claudeCode)
            var prepared: [String: [MarkdownBlockSnapshot]] = [:]
            var textBlockCount = 0
            for row in builtRows where row.role != .user {
                for block in row.blocks {
                    guard case let .text(_, text) = block else { continue }
                    textBlockCount += 1
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    let key = ChatMarkdownPrepared.key(for: text)
                    if prepared[key] != nil { continue }
                    if let blocks = CodeMessageHeightMeasurer.preparedBlocks(for: text) {
                        prepared[key] = blocks
                    }
                }
            }
            guard textBlockCount > 0, !prepared.isEmpty else {
                failures.append("rendererMeasure \(fixture.name): no prepared Markdown blocks"
                    + " (the hosted view would be empty)")
                continue
            }

            let renderedRecord = await measureRowHeight(group: group, fixture: fixture,
                                                        width: width, size: size,
                                                        window: window)
            let rendered = renderedRecord["rendered"] as? Double ?? -1
            guard rendered > 1 else {
                failures.append("rendererMeasure \(fixture.name): rendered \(rendered) pt,"
                    + " the measurement harness is unavailable")
                continue
            }

            let typography = TimelineChatContentAdapter.typography(
                dynamicType: String(describing: size.dynamicType),
                layoutDirection: 0,
                boldText: false,
                scale: CodePageTheme.markdownScale)
            let rowView = AnyView(CodeMessageRowView(group: group,
                                                     profile: .claudeCode,
                                                     cwd: "/repo",
                                                     typography: typography)
                .padding(.horizontal, margin)
                .ignoresSafeArea())

            // A: offscreen hosting controller, production prepared blocks.
            // The async parse task is skipped because the blocks are supplied.
            let hosting = UIHostingController(rootView: rowView)
            hosting.view.backgroundColor = .clear
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.traitOverrides.preferredContentSizeCategory = size.category
            hosting.view.bounds = CGRect(x: 0, y: 0, width: hostWidth, height: 1)
            hosting.view.layoutIfNeeded()
            let hostlessInset = hosting.view.safeAreaInsets
            let hostlessRaw = hosting.sizeThatFits(in: CGSize(
                width: hostWidth, height: .greatestFiniteMagnitude)).height
                - hostlessInset.top - hostlessInset.bottom
            let hostless: CGFloat = hostlessRaw.isFinite && hostlessRaw > 1
                ? ceil(hostlessRaw) : -1

            // B / C: the real cell with no seed, so `super` performs the first
            // fit. The cell goes into the key window: a detached cell cannot
            // lay out its hosted content, and the first CI run measured only
            // the row chrome (18 pt) both offscreen and detached. A fresh cell
            // per call keeps the configuration token and the (absent) seed out
            // of the other measurement.
            let cellSuper = await measureRendererCell(rowView, hostWidth: hostWidth,
                                                      window: window, forceLayout: false)
            let cellForced = await measureRendererCell(rowView, hostWidth: hostWidth,
                                                       window: window, forceLayout: true)
            // The immediate fit sees only the row chrome: SwiftUI has not
            // committed the hosted content yet even though the cell is in the
            // window. Give the content a runloop turn before the fit; this is
            // the earliest moment a synchronous self-measure can see the real
            // body.
            let cellSettled = await measureRendererCell(rowView, hostWidth: hostWidth,
                                                        window: window, forceLayout: false,
                                                        settleMilliseconds: 300)
            // The production settle reads the content view's own fitting size
            // (`settleVisibleCellHeightsOnce`), not the cell's preferred
            // attributes. Measure that exact call after the content commits.
            let contentSettled = await measureRendererContentFit(rowView, hostWidth: hostWidth,
                                                                 window: window)

            let hostlessValue = Double(hostless)
            let cellSuperValue = cellSuper.height.map { Double($0) } ?? -1
            let cellForcedValue = cellForced.height.map { Double($0) } ?? -1
            let cellSettledValue = cellSettled.height.map { Double($0) } ?? -1
            let hostlessAvailable = hostless > 1
            let hostlessDelta = hostlessAvailable ? abs(hostlessValue - rendered) : -1
            let cellSuperDelta = cellSuper.height != nil
                ? abs(cellSuperValue - rendered) : -1
            let cellForcedDelta = cellForced.height != nil
                ? abs(cellForcedValue - rendered) : -1
            let cellSettledDelta = cellSettled.height != nil
                ? abs(cellSettledValue - rendered) : -1
            let contentSettledValue = contentSettled.height.map { Double($0) } ?? -1
            let contentSettledDelta = contentSettled.height != nil
                ? abs(contentSettledValue - rendered) : -1
            if hostlessAvailable {
                hostlessMaxDelta = max(hostlessMaxDelta, hostlessDelta)
            }
            if cellSuper.height != nil {
                cellSuperMaxDelta = max(cellSuperMaxDelta, cellSuperDelta)
            }
            if cellForced.height != nil {
                cellForcedMaxDelta = max(cellForcedMaxDelta, cellForcedDelta)
            }
            if cellSettled.height != nil {
                cellSettledMaxDelta = max(cellSettledMaxDelta, cellSettledDelta)
            }
            if contentSettled.height != nil {
                contentSettledMaxDelta = max(contentSettledMaxDelta, contentSettledDelta)
            }

            var record: [String: Any] = [:]
            record["fixture"] = fixture.name
            record["width"] = Double(width)
            record["dynamicType"] = size.name
            record["rendered"] = rendered
            record["hostlessAvailable"] = hostlessAvailable
            record["hostless"] = hostlessValue
            record["hostlessDelta"] = hostlessDelta
            record["hostlessWithin1"] = hostlessAvailable && hostlessDelta <= 1
            record["hostlessWithin3"] = hostlessAvailable && hostlessDelta <= 3
            record["cellSuperAvailable"] = cellSuper.height != nil
            record["cellSuperContentInstalled"] = cellSuper.contentInstalled
            record["cellSuperSafeTop"] = Double(cellSuper.safeTop)
            record["cellSuperSafeBottom"] = Double(cellSuper.safeBottom)
            record["cellSuper"] = cellSuperValue
            record["cellSuperDelta"] = cellSuperDelta
            record["cellSuperWithin1"] = cellSuper.height != nil && cellSuperDelta <= 1
            record["cellSuperWithin3"] = cellSuper.height != nil && cellSuperDelta <= 3
            record["cellForcedAvailable"] = cellForced.height != nil
            record["cellForcedContentInstalled"] = cellForced.contentInstalled
            record["cellForcedSafeTop"] = Double(cellForced.safeTop)
            record["cellForcedSafeBottom"] = Double(cellForced.safeBottom)
            record["cellForced"] = cellForcedValue
            record["cellForcedDelta"] = cellForcedDelta
            record["cellForcedWithin1"] = cellForced.height != nil && cellForcedDelta <= 1
            record["cellForcedWithin3"] = cellForced.height != nil && cellForcedDelta <= 3
            record["cellSettledAvailable"] = cellSettled.height != nil
            record["cellSettledContentInstalled"] = cellSettled.contentInstalled
            record["cellSettledSafeTop"] = Double(cellSettled.safeTop)
            record["cellSettledSafeBottom"] = Double(cellSettled.safeBottom)
            record["cellSettled"] = cellSettledValue
            record["cellSettledDelta"] = cellSettledDelta
            record["cellSettledWithin1"] = cellSettled.height != nil && cellSettledDelta <= 1
            record["cellSettledWithin3"] = cellSettled.height != nil && cellSettledDelta <= 3
            record["contentSettledAvailable"] = contentSettled.height != nil
            record["contentSettledSafeTop"] = Double(contentSettled.safeTop)
            record["contentSettledSafeBottom"] = Double(contentSettled.safeBottom)
            record["contentSettled"] = contentSettledValue
            record["contentSettledDelta"] = contentSettledDelta
            record["contentSettledWithin1"] = contentSettled.height != nil
                && contentSettledDelta <= 1
            record["contentSettledWithin3"] = contentSettled.height != nil
                && contentSettledDelta <= 3
            cases.append(record)

            print("AA RENDERER MEASURE \(fixture.name)"
                + " rendered=\(rendered)"
                + " hostless=\(hostlessValue) d=\(hostlessDelta)"
                + " cell=\(cellSuperValue) d=\(cellSuperDelta)"
                + " cellForced=\(cellForcedValue) d=\(cellForcedDelta)"
                + " cellSettled=\(cellSettledValue) d=\(cellSettledDelta)"
                + " contentSettled=\(contentSettledValue) d=\(contentSettledDelta)")
        }

        var measurement: [String: Any] = [:]
        measurement["fixtureCount"] = Self.rendererMeasureFixtures.count
        measurement["caseCount"] = cases.count
        measurement["threshold"] = 1.0
        measurement["parityThreshold"] = 3.0
        measurement["renderedSource"] = "measureRowHeight: settled in-window host"
        measurement["hostlessSource"] = "offscreen UIHostingController, preparedBlocks, ceil"
        measurement["cellSuperSource"] = "TimelineHostingCell in the key window, no seed, direct preferredLayoutAttributesFitting"
        measurement["cellForcedSource"] = "TimelineHostingCell in the key window, no seed, contentView layout before the fit"
        measurement["cellSettledSource"] = "TimelineHostingCell in the key window, no seed, 300 ms runloop before the fit"
        measurement["contentSettledSource"] = "cell.contentView.systemLayoutSizeFitting after a 300 ms commit (the production settle call)"
        measurement["hostlessMaxDelta"] = hostlessMaxDelta
        measurement["cellSuperMaxDelta"] = cellSuperMaxDelta
        measurement["cellForcedMaxDelta"] = cellForcedMaxDelta
        measurement["cellSettledMaxDelta"] = cellSettledMaxDelta
        measurement["contentSettledMaxDelta"] = contentSettledMaxDelta
        measurement["cases"] = cases
        report["rendererMeasure"] = measurement
        persist(phase: "views.rendererMeasure")
    }

    private struct RendererCellMeasurement {
        /// `nil` when the fit returned no usable height (the harness failed to
        /// install and measure the hosted content).
        let height: CGFloat?
        /// Whether `UIHostingConfiguration` installed a content subview. A fit
        /// can return a probe/frame height without the real content, so this
        /// distinguishes "no harness" from "harness measured the skeleton".
        let contentInstalled: Bool
        /// The cell's safe-area insets at fit time. The production cell
        /// subtracts them from its geometry report; the raw fit may include
        /// them, so the reader needs both numbers before comparing to the
        /// in-window render.
        let safeTop: CGFloat
        let safeBottom: CGFloat
    }

    /// One `TimelineHostingCell` first-fit measurement. The cell is added to
    /// the key window so `UIHostingConfiguration` installs and lays out its
    /// hosted content the way it would in the collection view; a detached cell
    /// measures only the row chrome. `forceLayout` additionally gives the
    /// content view its own layout pass before the fit.
    private func measureRendererCell(_ row: AnyView,
                                     hostWidth: CGFloat,
                                     window: UIWindow,
                                     forceLayout: Bool,
                                     settleMilliseconds: Int = 0) async -> RendererCellMeasurement {
        let cell = TimelineHostingCell(frame: CGRect(x: 0, y: 0,
                                                     width: hostWidth, height: 300))
        cell.configure(row, policy: .measured,
                       isMeasured: false, reportsContentHeight: false,
                       seededHeight: nil)
        window.addSubview(cell)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        if settleMilliseconds > 0 {
            await wait(settleMilliseconds)
            window.layoutIfNeeded()
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
        }
        if forceLayout {
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
        }
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: hostWidth, height: 300)
        let fitted = cell.preferredLayoutAttributesFitting(attributes).size.height
        let installed = !cell.contentView.subviews.isEmpty
        let safeTop = cell.safeAreaInsets.top
        let safeBottom = cell.safeAreaInsets.bottom
        cell.removeFromSuperview()
        guard fitted.isFinite, fitted > 1 else {
            return RendererCellMeasurement(height: nil, contentInstalled: installed,
                                           safeTop: safeTop, safeBottom: safeBottom)
        }
        return RendererCellMeasurement(height: fitted, contentInstalled: installed,
                                       safeTop: safeTop, safeBottom: safeBottom)
    }

    /// The production settle call: read the cell's content view fitting size
    /// after the hosted content has had a runloop turn to commit. The visible
    /// cell settle (`settleVisibleCellHeightsOnce`) uses exactly this call, so
    /// this is the renderer's own height without the preferred-attributes
    /// wrapper.
    private func measureRendererContentFit(_ row: AnyView,
                                           hostWidth: CGFloat,
                                           window: UIWindow) async
        -> (height: CGFloat?, safeTop: CGFloat, safeBottom: CGFloat) {
        let cell = TimelineHostingCell(frame: CGRect(x: 0, y: 0,
                                                     width: hostWidth, height: 300))
        cell.configure(row, policy: .measured,
                       isMeasured: false, reportsContentHeight: false,
                       seededHeight: nil)
        window.addSubview(cell)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        await wait(300)
        window.layoutIfNeeded()
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        let width = cell.contentView.bounds.width
        let raw: CGFloat
        if width > 0 {
            raw = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
        } else {
            raw = .nan
        }
        let safeTop = cell.safeAreaInsets.top
        let safeBottom = cell.safeAreaInsets.bottom
        cell.removeFromSuperview()
        let height: CGFloat? = raw.isFinite && raw > 1 ? ceil(raw) : nil
        return (height, safeTop, safeBottom)
    }

    // MARK: - Real collection first fit (3 pt correction)

    /// Replays the three renderer fixtures inside a real self-sizing
    /// `UICollectionView` instead of a cell placed directly in the window.
    ///
    /// The 466 run showed that a cell outside a collection view measures only
    /// its chrome (86 pt = safe area + row chrome): the client's normal
    /// `cellForItemAt` never runs, so `UIHostingConfiguration` never installs
    /// the hosted body. This leg asks the next question: when the collection
    /// view itself lays the item out, does its first layout — the moment
    /// `preferredLayoutAttributesFitting` decides the row height — already see
    /// the body? Three variants per fixture:
    ///
    /// - `normal`: `cellForItemAt` only configures the cell.
    /// - `forced`: the same, plus a cell and content-view layout pass before
    ///   returning the cell.
    /// - `seeded`: `configure(seededHeight:)` with the structural measurement,
    ///   which the cell must return as the first-fit height.
    ///
    /// Deltas are recorded, never asserted. Only a broken harness (no cell, no
    /// layout attributes, no settled fit) appends a failure — the main session
    /// reads the numbers and decides whether the first fit can carry the real
    /// body.
    private func verifyRealCollectionFirstFit() async {
        guard let window = keyWindow else {
            failures.append("realCollectionFirstFit: no key window")
            return
        }
        let margin = CodePageTheme.rowMarginLeading
        let estimateHeight: CGFloat = 200
        var cases: [[String: Any]] = []
        var expected = 0

        for fixture in Self.rendererMeasureFixtures {
            guard let items = Self.decodeItems(fixture.json) else {
                failures.append("realCollectionFirstFit \(fixture.name): fixture JSON did not decode")
                continue
            }
            guard let width = fixture.widths.first,
                  let size = fixture.sizes.first else {
                failures.append("realCollectionFirstFit \(fixture.name): fixture has no width or size")
                continue
            }
            let group = ChatTimelineGroup(kind: .single,
                rows: items.map { ChatTimelineRowModel($0) },
                explicitID: "gate-real-collection-\(fixture.name)")
            let hostWidth = width + 2 * margin

            // The adapter's `preparedTextBlocks` rule, identical to
            // `verifyRendererMeasure`: one parse per non-user `.text` block,
            // keyed by the text the row draws, so the cell skips its async
            // parse task.
            let builtRows = CodeMessageBuilder.rows(for: items, profile: .claudeCode)
            var prepared: [String: [MarkdownBlockSnapshot]] = [:]
            for row in builtRows where row.role != .user {
                for block in row.blocks {
                    guard case let .text(_, text) = block else { continue }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    let key = ChatMarkdownPrepared.key(for: text)
                    if prepared[key] != nil { continue }
                    if let blocks = CodeMessageHeightMeasurer.preparedBlocks(for: text) {
                        prepared[key] = blocks
                    }
                }
            }
            guard !prepared.isEmpty else {
                failures.append("realCollectionFirstFit \(fixture.name): no prepared Markdown blocks")
                continue
            }

            let typography = TimelineChatContentAdapter.typography(
                dynamicType: String(describing: size.dynamicType),
                layoutDirection: 0,
                boldText: false,
                scale: CodePageTheme.markdownScale)
            let rowView = AnyView(CodeMessageRowView(group: group,
                                                     profile: .claudeCode,
                                                     cwd: "/repo",
                                                     typography: typography)
                .padding(.horizontal, margin)
                .ignoresSafeArea())

            // The structural value the production provider would seed with.
            // The cell ceils the seed, so record both the measurer output and
            // the value actually passed in.
            let traits = UITraitCollection(traitsFrom: [
                window.traitCollection,
                UITraitCollection(preferredContentSizeCategory: size.category),
            ])
            let structural = CodeMessageHeightMeasurer.height(
                group: group, profile: .claudeCode, width: width,
                typography: typography, traits: traits, measured: true)
            let seed = ceil(structural)

            let normal = await measureRealCollectionVariant(
                rowView, hostWidth: hostWidth, category: size.category,
                window: window, forceContentLayout: false,
                seed: nil, estimateHeight: estimateHeight)
            let forced = await measureRealCollectionVariant(
                rowView, hostWidth: hostWidth, category: size.category,
                window: window, forceContentLayout: true,
                seed: nil, estimateHeight: estimateHeight)
            let seeded = await measureRealCollectionVariant(
                rowView, hostWidth: hostWidth, category: size.category,
                window: window, forceContentLayout: false,
                seed: seed, estimateHeight: estimateHeight)
            expected += 3

            let variants: [(name: String, measurement: RealCollectionVariantMeasurement)] = [
                ("normal", normal), ("forced", forced), ("seeded", seeded),
            ]
            for (name, measurement) in variants {
                if !measurement.cellAvailable {
                    failures.append("realCollectionFirstFit \(fixture.name) [\(name)]:"
                        + " the collection view created no cell")
                }
                if measurement.firstFit == nil {
                    failures.append("realCollectionFirstFit \(fixture.name) [\(name)]:"
                        + " no layout attributes for the first layout")
                }
                if measurement.settledFit == nil {
                    failures.append("realCollectionFirstFit \(fixture.name) [\(name)]:"
                        + " settled fit unavailable (<= 1 pt)")
                }
            }

            let normalRecord = realCollectionVariantRecord(normal, estimateHeight: estimateHeight,
                                                           seed: nil)
            let forcedRecord = realCollectionVariantRecord(forced, estimateHeight: estimateHeight,
                                                           seed: nil)
            let seededRecord = realCollectionVariantRecord(seeded, estimateHeight: estimateHeight,
                                                           seed: seed)

            let normalFit = Self.doubleValue(normal.firstFit)
            let forcedFit = Self.doubleValue(forced.firstFit)
            let seededFit = Self.doubleValue(seeded.firstFit)
            let seedValue = Double(seed)
            let normalSettled = Self.doubleValue(normal.settledFit)
            let forcedSettled = Self.doubleValue(forced.settledFit)
            let seededSettled = Self.doubleValue(seeded.settledFit)

            var record: [String: Any] = [:]
            record["fixture"] = fixture.name
            record["width"] = Double(width)
            record["hostWidth"] = Double(hostWidth)
            record["dynamicType"] = size.name
            record["estimatedItemHeight"] = Double(estimateHeight)
            record["firstFit"] = normalFit
            record["firstFitForced"] = forcedFit
            record["seededFirstFit"] = seededFit
            record["seededInput"] = Double(structural)
            record["seededValue"] = seedValue
            record["seededSource"] = "CodeMessageHeightMeasurer.height (ceiled by the cell)"
            record["settledFit"] = normalSettled
            record["settledFitForced"] = forcedSettled
            record["settledFitSeeded"] = seededSettled
            record["safeTop"] = Double(normal.safeTop)
            record["safeBottom"] = Double(normal.safeBottom)
            record["firstFitDeltaFromSettled"] = Self.deltaValue(normal.firstFit, normal.settledFit)
            record["forcedDeltaFromSettled"] = Self.deltaValue(forced.firstFit, forced.settledFit)
            record["seededDeltaFromSeed"] = Self.deltaValue(seeded.firstFit, seed)
            record["seededDeltaFromSettled"] = Self.deltaValue(seeded.firstFit, seeded.settledFit)
            var variantRecords: [String: Any] = [:]
            variantRecords["normal"] = normalRecord
            variantRecords["forced"] = forcedRecord
            variantRecords["seeded"] = seededRecord
            record["variants"] = variantRecords
            cases.append(record)

            // The CI log carries the table even when the JSON artifact is the
            // only thing a later reader has.
            print("AA REAL COLLECTION \(fixture.name)"
                + " firstFit=\(normalFit) forced=\(forcedFit) seeded=\(seededFit)"
                + " seededValue=\(seedValue) settled=\(normalSettled)"
                + " settledForced=\(forcedSettled) settledSeeded=\(seededSettled)"
                + " safeTop=\(Double(normal.safeTop)) safeBottom=\(Double(normal.safeBottom))")
        }

        var measurement: [String: Any] = [:]
        measurement["fixtureCount"] = Self.rendererMeasureFixtures.count
        measurement["caseCount"] = cases.count
        measurement["expectedCaseCount"] = expected
        measurement["estimatedItemHeight"] = Double(estimateHeight)
        measurement["widths"] = [361.0]
        measurement["layout"] = "UICollectionViewFlowLayout, estimatedItemSize (hostWidth x 200), default self-sizing invalidation"
        measurement["firstFitSource"] = "collectionView.layoutAttributesForItem(at: [0,0]) after reloadData + layoutIfNeeded"
        measurement["forcedSource"] = "cell.configure + cell.setNeedsLayout/layoutIfNeeded + contentView.layoutIfNeeded inside cellForItemAt"
        measurement["seededSource"] = "cell.configure(seededHeight: ceil(CodeMessageHeightMeasurer.height))"
        measurement["settledSource"] = "contentView.systemLayoutSizeFitting after 300 ms and two layout passes"
        measurement["cases"] = cases
        report["realCollectionFirstFit"] = measurement
        persist(phase: "views.realCollectionFirstFit")
    }

    private struct RealCollectionVariantMeasurement {
        /// The height the collection view's first layout adopted for item 0.
        let firstFit: CGFloat?
        /// The height the same item's attributes carry after the 300 ms
        /// settle. Diagnostic: it separates "the flow layout never asked the
        /// cell" (still the estimate) from "it asked late" (the real body).
        let settledAttributesFit: CGFloat?
        /// The production settle call: `contentView.systemLayoutSizeFitting`.
        let settledFit: CGFloat?
        /// `settledFit` minus the cell's safe-area insets. Recorded for the
        /// reader; the deltas use the raw value.
        let settledFitNet: CGFloat?
        let safeTop: CGFloat
        let safeBottom: CGFloat
        /// The collection view created and returned the item's cell.
        let cellAvailable: Bool
        /// `UIHostingConfiguration` installed a hosted content subview.
        let contentInstalled: Bool
    }

    /// One-item data source. A plain implementation (not diffable) keeps
    /// `reloadData()` + `layoutIfNeeded()` deterministic: the first layout
    /// must create the cell synchronously so the reported attributes are what
    /// the collection view actually adopted.
    @MainActor
    private final class RealCollectionCellSource: NSObject, UICollectionViewDataSource {
        var makeCell: ((UICollectionView, IndexPath) -> UICollectionViewCell)?

        func collectionView(_ collectionView: UICollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            1
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let makeCell else { return UICollectionViewCell(frame: .zero) }
            return makeCell(collectionView, indexPath)
        }
    }

    /// Lays one row out in a fresh collection view and reads the height the
    /// first layout adopted, then the exact call the production visible-cell
    /// settle makes after the hosted content has had 300 ms to commit. A fresh
    /// collection view per call keeps the layout, the cell and the (absent)
    /// seed from leaking into another variant.
    private func measureRealCollectionVariant(_ row: AnyView,
                                              hostWidth: CGFloat,
                                              category: UIContentSizeCategory,
                                              window: UIWindow,
                                              forceContentLayout: Bool,
                                              seed: CGFloat?,
                                              estimateHeight: CGFloat) async
        -> RealCollectionVariantMeasurement {
        let layout = UICollectionViewFlowLayout()
        layout.estimatedItemSize = CGSize(width: hostWidth, height: estimateHeight)
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: hostWidth, height: 800),
            collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        // Fixtures are regular (.large); the override keeps the collection
        // view's traits on the fixture even if the simulator is set
        // differently. It does not affect when the layout asks the cell to fit.
        collectionView.traitOverrides.preferredContentSizeCategory = category
        collectionView.register(TimelineHostingCell.self,
                                forCellWithReuseIdentifier: TimelineHostingCell.reuseIdentifier)

        let source = RealCollectionCellSource()
        source.makeCell = { collectionView, indexPath in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TimelineHostingCell.reuseIdentifier,
                for: indexPath) as! TimelineHostingCell
            cell.configure(row, policy: .measured,
                           isMeasured: false, reportsContentHeight: false,
                           seededHeight: seed)
            if forceContentLayout {
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
                cell.contentView.layoutIfNeeded()
            }
            return cell
        }
        collectionView.dataSource = source
        window.addSubview(collectionView)
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        let indexPath = IndexPath(item: 0, section: 0)
        let firstAttributes = collectionView.layoutAttributesForItem(at: indexPath)
        let firstCell = collectionView.cellForItem(at: indexPath)

        await wait(300)
        collectionView.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        let settledAttributes = collectionView.layoutAttributesForItem(at: indexPath)
        let settledCell = collectionView.cellForItem(at: indexPath) ?? firstCell

        let safeTop = settledCell?.safeAreaInsets.top ?? 0
        let safeBottom = settledCell?.safeAreaInsets.bottom ?? 0
        let cellAvailable = settledCell != nil
        let installed = settledCell.map { !$0.contentView.subviews.isEmpty } ?? false

        var settledRaw: CGFloat = .nan
        if let cell = settledCell {
            let contentWidth = cell.contentView.bounds.width
            if contentWidth > 0 {
                settledRaw = cell.contentView.systemLayoutSizeFitting(
                    CGSize(width: contentWidth,
                           height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel).height
            }
        }
        collectionView.removeFromSuperview()
        source.makeCell = nil

        let firstFit: CGFloat?
        if let height = firstAttributes?.size.height, height.isFinite, height > 0 {
            firstFit = height
        } else {
            firstFit = nil
        }
        let settledAttributesFit: CGFloat?
        if let height = settledAttributes?.size.height, height.isFinite, height > 0 {
            settledAttributesFit = height
        } else {
            settledAttributesFit = nil
        }
        let settledFit: CGFloat? = settledRaw.isFinite && settledRaw > 1
            ? ceil(settledRaw) : nil
        let settledFitNet: CGFloat? = settledFit.map {
            max(0, $0 - safeTop - safeBottom)
        }
        return RealCollectionVariantMeasurement(
            firstFit: firstFit,
            settledAttributesFit: settledAttributesFit,
            settledFit: settledFit,
            settledFitNet: settledFitNet,
            safeTop: safeTop,
            safeBottom: safeBottom,
            cellAvailable: cellAvailable,
            contentInstalled: installed)
    }

    private func realCollectionVariantRecord(
        _ measurement: RealCollectionVariantMeasurement,
        estimateHeight: CGFloat,
        seed: CGFloat?
    ) -> [String: Any] {
        var record: [String: Any] = [:]
        record["firstFit"] = Self.doubleValue(measurement.firstFit)
        record["firstFitAvailable"] = measurement.firstFit != nil
        record["firstFitEqualsEstimate"] = Self.withinHalfPoint(measurement.firstFit,
                                                                estimateHeight)
        record["settledAttributesFit"] = Self.doubleValue(measurement.settledAttributesFit)
        record["settledFit"] = Self.doubleValue(measurement.settledFit)
        record["settledFitAvailable"] = measurement.settledFit != nil
        record["settledFitNet"] = Self.doubleValue(measurement.settledFitNet)
        record["safeTop"] = Double(measurement.safeTop)
        record["safeBottom"] = Double(measurement.safeBottom)
        record["cellAvailable"] = measurement.cellAvailable
        record["contentInstalled"] = measurement.contentInstalled
        record["firstFitDeltaFromSettled"] = Self.deltaValue(measurement.firstFit,
                                                             measurement.settledFit)
        if let seed {
            record["seed"] = Double(seed)
            record["firstFitEqualsSeed"] = Self.withinHalfPoint(measurement.firstFit, seed)
            record["firstFitDeltaFromSeed"] = Self.deltaValue(measurement.firstFit, seed)
        }
        return record
    }

    private static func doubleValue(_ value: CGFloat?) -> Double {
        guard let value, value.isFinite else { return -1 }
        return Double(value)
    }

    private static func deltaValue(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Double {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite else { return -1 }
        return Double(abs(lhs - rhs))
    }

    private static func withinHalfPoint(_ value: CGFloat?, _ target: CGFloat) -> Bool {
        guard let value, value.isFinite else { return false }
        return abs(value - target) <= 0.5
    }

    /// Hosts one `CodeMessageRowView` the way `verifyMessageRowHeight` does:
    /// add it to the key window so `ChatMarkdownView`'s parse task runs, let
    /// the fitting height settle, then measure the same hierarchy off the
    /// window — `sizeThatFits` keeps the window's safe-area insets even with
    /// `.ignoresSafeArea()`, and the timeline row has none.
    ///
    /// `width` is the row's content width (the collection column minus the
    /// 16 pt horizontal margins); the host is that width plus both margins so
    /// the row lays out at exactly the measured width.
    private func measureRowHeight(group: ChatTimelineGroup,
                                  fixture: RowHeightFixture,
                                  width: CGFloat,
                                  size: RowHeightFixture.Size,
                                  window: UIWindow) async -> [String: Any] {
        let margin = CodePageTheme.rowMarginLeading
        let hostWidth = width + 2 * margin
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: String(describing: size.dynamicType),
            layoutDirection: 0,
            boldText: false)
        let host = UIHostingController(rootView:
            CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo",
                               typography: typography)
                .padding(.horizontal, margin)
                .ignoresSafeArea())
        host.view.backgroundColor = .clear
        host.traitOverrides.preferredContentSizeCategory = size.category
        host.view.frame = CGRect(x: 0, y: 0, width: hostWidth, height: 120)
        window.addSubview(host.view)
        host.view.layoutIfNeeded()

        let proposed = CGSize(width: hostWidth, height: .greatestFiniteMagnitude)
        var settled = host.sizeThatFits(in: proposed).height
        var previous: CGFloat = -1
        // Poll the fitting height: an async Markdown parse publishes its
        // blocks after the first layout pass, and a pure tool row settles on
        // the first. A stable pair ends the wait; 4 s is the ceiling.
        for _ in 0..<40 {
            await wait(100)
            host.view.layoutIfNeeded()
            settled = host.sizeThatFits(in: proposed).height
            if settled > 1, abs(settled - previous) <= 0.5 { break }
            previous = settled
        }
        let inWindow = settled
        let safeTop = host.view.safeAreaInsets.top
        let safeBottom = host.view.safeAreaInsets.bottom
        let traits = UITraitCollection(traitsFrom: [
            window.traitCollection,
            UITraitCollection(preferredContentSizeCategory: size.category),
        ])

        host.view.removeFromSuperview()
        host.view.frame = CGRect(x: 0, y: 0, width: hostWidth, height: 120)
        host.view.layoutIfNeeded()
        let rendered = max(0, host.sizeThatFits(in: proposed).height
            - safeTop - safeBottom)

        let measured = CodeMessageHeightMeasurer.height(
            group: group, profile: .claudeCode,
            width: width, typography: typography, traits: traits, measured: true)
        return ["measured": Double(measured),
                "rendered": Double(rendered),
                "delta": Double(abs(measured - rendered)),
                "inWindow": Double(inWindow),
                "safeTop": Double(safeTop),
                "safeBottom": Double(safeBottom),
                "hostWidth": Double(hostWidth),
                "contentWidth": Double(width)]
    }

    /// A known-pixel expectation for one capture. The background point is the
    /// page's 16 pt leading margin; the ink band is a vertical fraction of
    /// the image that must contain glyph pixels.
    private struct CapturePixelCheck {
        enum Background {
            case light
            case dark
        }

        enum Ink {
            /// Dark glyphs on a light surface (light-mode captures).
            case dark
            /// Light glyphs on a dark surface (the dark gallery).
            case bright
        }

        var background: Background?
        var ink: Ink?
        var inkBand: ClosedRange<CGFloat> = 0.25...0.95
        var minimumInkPixels: Int = 200
        /// Dark mode only: the `text100` target run resolves to
        /// (249,249,247). At least this many pixels must match it ±2 so the
        /// gallery cannot pass with light-mode tokens on a dark background.
        var minimumTargetPixels: Int = 0
    }

    /// Captures the app window. The stage view fills it, so the PNG shows the
    /// component at its real width and Dynamic Type, with the same chrome the
    /// simulator run has (status bar, background).
    private func capture(_ name: String,
                         check: CapturePixelCheck? = nil) -> [String: Any] {
        guard let window = keyWindow, window.bounds.width > 0 else {
            failures.append("views: no key window for \(name)")
            return ["error": "no key window"]
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            failures.append("views: \(name) produced no PNG data")
            return ["error": "no png"]
        }
        let url = documentsDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
        } catch {
            failures.append("views: \(name) write failed: \(error.localizedDescription)")
        }
        if data.count < 2000 {
            failures.append("views: \(name) is \(data.count) bytes, expected a rendered frame")
        }
        // A blank window still compresses to a large PNG; sample the middle
        // band so a capture that rendered nothing is caught as a failure.
        let sampledColors = distinctColors(in: image)
        if sampledColors < 2 {
            failures.append("views: \(name) sampled \(sampledColors) colour(s), expected rendered content")
        }
        var detail: [String: Any] = [
            "bytes": data.count,
            "width": Double(image.size.width),
            "height": Double(image.size.height),
            "distinctColors": sampledColors,
        ]
        if let check {
            detail["pixelCheck"] = verifyPixels(image, name: name, check: check)
        }
        return detail
    }

    /// Asserts the capture's known pixels: the page background at the leading
    /// margin and, when requested, a minimum amount of ink inside a band that
    /// excludes the navigation bar and header.
    private func verifyPixels(_ image: UIImage,
                              name: String,
                              check: CapturePixelCheck) -> [String: Any] {
        guard let cgImage = image.cgImage else {
            failures.append("views: \(name) has no CGImage for the pixel check")
            return ["error": "no cgImage"]
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            failures.append("views: \(name) pixel data unavailable")
            return ["error": "no pixel data"]
        }
        // Redraw into a known 8-bit sRGB buffer. The renderer's own CGImage
        // may be extended-range/16-bit (the first CI run read magenta garbage
        // from a uniform #F9F9F7 background), so sampling its raw bytes with
        // a fixed BGRA stride is not safe. The flipped context keeps buffer
        // row 0 at the image's top, matching the band coordinates below.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            failures.append("views: \(name) pixel context unavailable")
            return ["error": "no pixel context"]
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            failures.append("views: \(name) pixel data unavailable")
            return ["error": "no pixel data"]
        }
        let bytes = data.bindMemory(to: UInt8.self, capacity: height * width * 4)
        let bytesPerPixel = 4
        func rgb(x: Int, y: Int) -> (Int, Int, Int) {
            let offset = y * context.bytesPerRow + x * bytesPerPixel
            return (Int(bytes[offset]),
                    Int(bytes[offset + 1]),
                    Int(bytes[offset + 2]))
        }
        var result: [String: Any] = [:]
        var passed = true

        if let background = check.background {
            // 2% of the width is inside the 16 pt outer margin on every
            // supported phone; mid-height avoids the status bar and home
            // indicator.
            let sample = rgb(x: max(0, width / 50), y: height / 2)
            let expected = background == .light ? (249, 249, 247) : (21, 21, 21)
            let match = abs(sample.0 - expected.0) <= 2
                && abs(sample.1 - expected.1) <= 2
                && abs(sample.2 - expected.2) <= 2
            result["background"] = [sample.0, sample.1, sample.2]
            result["backgroundExpected"] = [expected.0, expected.1, expected.2]
            result["backgroundPassed"] = match
            if !match {
                passed = false
                failures.append(
                    "views: \(name) background \(sample), expected \(expected) ±2")
            }
        }

        if let ink = check.ink {
            let minY = Int(CGFloat(height) * check.inkBand.lowerBound)
            let maxY = Int(CGFloat(height) * check.inkBand.upperBound)
            // Stay inside the card body: the 1 px card border is dark in
            // light mode and would otherwise satisfy a blank capture.
            let minX = Int(CGFloat(width) * 0.10)
            let maxX = Int(CGFloat(width) * 0.90)
            var count = 0
            var targetCount = 0
            var y = minY
            while y < maxY {
                var x = minX
                while x < maxX {
                    let color = rgb(x: x, y: y)
                    switch ink {
                    case .dark:
                        if color.0 < 96, color.1 < 96, color.2 < 96 { count += 1 }
                    case .bright:
                        if color.0 > 235, color.1 > 235, color.2 > 230 { count += 1 }
                        // text100 dark = (249,249,247).
                        if abs(color.0 - 249) <= 2,
                           abs(color.1 - 249) <= 2,
                           abs(color.2 - 247) <= 2 {
                            targetCount += 1
                        }
                    }
                    x += 2
                }
                y += 2
            }
            result["inkPixels"] = count
            result["inkExpected"] = check.minimumInkPixels
            result["inkPassed"] = count >= check.minimumInkPixels
            if count < check.minimumInkPixels {
                passed = false
                failures.append(
                    "views: \(name) has \(count) ink pixels, expected ≥ \(check.minimumInkPixels)")
            }
            if check.minimumTargetPixels > 0 {
                result["targetPixels"] = targetCount
                result["targetExpected"] = check.minimumTargetPixels
                result["targetPassed"] = targetCount >= check.minimumTargetPixels
                if targetCount < check.minimumTargetPixels {
                    passed = false
                    failures.append(
                        "views: \(name) has \(targetCount) text100-dark pixels,"
                            + " expected ≥ \(check.minimumTargetPixels)")
                }
            }
        }

        result["passed"] = passed
        return result
    }

    /// Distinct colours in the middle band of a downscaled copy. The status bar
    /// and home indicator are excluded; a rendered component leaves more than
    /// one colour, a blank background leaves exactly one.
    private func distinctColors(in image: UIImage) -> Int {
        let size = CGSize(width: 32, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = small.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              cgImage.bitsPerPixel >= 32 else { return 0 }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let minY = cgImage.height / 4
        let maxY = cgImage.height - cgImage.height / 4
        var colors: Set<UInt32> = []
        var y = minY
        while y < maxY {
            var x = 0
            while x < cgImage.width {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                let value = UInt32(bytes[offset])
                    | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16
                    | UInt32(bytes[offset + 3]) << 24
                colors.insert(value)
                x += 1
            }
            y += 1
        }
        return colors.count
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Report

    private func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        failures.append(message())
    }

    /// Writes a checkpoint after a phase. `completed` stays false so a crash
    /// later in the gate still leaves the last phase and its failures on disk.
    private func persist(phase: String) {
        report["phase"] = phase
        writeReport(completed: false)
    }

    private func finish() {
        report["phase"] = "finished"
        report["gateVersion"] = 1
        writeReport(completed: true)
    }

    private func writeReport(completed: Bool) {
        var output = report
        output["failures"] = failures
        output["completed"] = completed
        output["passed"] = completed && failures.isEmpty
        output["device"] = UIDevice.current.name
        output["system"] = UIDevice.current.systemVersion
        output["launchArgument"] = Self.launchArgument
        guard let data = try? JSONSerialization.data(
            withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: documentsDirectory.appendingPathComponent(Self.resultFileName))
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - Fixtures

    private static func decodeItems(_ json: String) -> [V2TimelineItem]? {
        try? JSONDecoder().decode([V2TimelineItem].self, from: Data(json.utf8))
    }

    private static func decodeItem(_ json: String) -> V2TimelineItem? {
        try? JSONDecoder().decode(V2TimelineItem.self, from: Data(json.utf8))
    }

    private static let runtimeFixtures: [RuntimeFixture] = [
        RuntimeFixture(
            name: "claude",
            family: .claudeCode,
            profile: .claudeCode,
            messageID: "cl-msg-1",
            unknownID: "cl-t7",
            skippedIDs: ["cl-t5", "cl-t6"],
            expectsSpecial: true,
            expectedBlocks: ["reasoning:cl-r1", "text:cl-m1", "toolCalls"],
            expectedSegments: [
                "span(cl-t1,cl-t2,cl-t3)",
                "special(workflow,cl-t4)",
                "span(cl-t7)",
            ],
            expectedKinds: [.read, .bash, .search, .other, .other],
            json: CodeProfileAutoRunModel.claudeFixtureJSON),
        RuntimeFixture(
            name: "codex",
            family: .codex,
            profile: .codex,
            messageID: "cx-msg-1",
            unknownID: "cx-t5",
            skippedIDs: ["cx-t4"],
            expectsSpecial: false,
            expectedBlocks: ["reasoning:cx-r1", "text:cx-m1", "toolCalls"],
            expectedSegments: ["span(cx-t1,cx-t2,cx-t3,cx-t5,cx-t6)"],
            expectedKinds: [.edit, .bash, .search, .other, .other],
            json: CodeProfileAutoRunModel.codexFixtureJSON),
        RuntimeFixture(
            name: "dsh",
            family: .dsh,
            profile: .dsh,
            messageID: "dsh-msg-1",
            unknownID: "dsh-t5",
            skippedIDs: [],
            expectsSpecial: false,
            expectedBlocks: ["reasoning:dsh-r1", "text:dsh-m1", "toolCalls"],
            expectedSegments: ["span(dsh-t1,dsh-t2,dsh-t3,dsh-t4,dsh-t5,dsh-t6)"],
            expectedKinds: [.bash, .search, .edit, .task, .other, .plan],
            json: CodeProfileAutoRunModel.dshFixtureJSON),
    ]

    /// Arrival order is body → tools → reasoning on purpose: the builder must
    /// emit the declared RBT order (reasoning, body, tools) regardless.
    /// The tool list carries every segmentation case: a three-call span, the
    /// `Workflow` special, the two skipped Claude tools, and an unknown name.
    private static let claudeFixtureJSON = #"""
    [
      {"id":"cl-m1","sessionId":"gate-claude","type":"message","status":"done","role":"assistant","orderSeq":3,
       "content":{"text":"The build passes after two edits: `Package.swift` and `App.swift`."},
       "source":{"itemId":"cl-msg-1"}},
      {"id":"cl-t1","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":5,
       "content":{"toolName":"Read","input":{"file_path":"/repo/Sources/App.swift"}},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":0}},
      {"id":"cl-t2","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":6,
       "content":{"toolName":"Bash","input":{"command":"swift test"}},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":1}},
      {"id":"cl-t3","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":7,
       "content":{"toolName":"Grep","input":{"pattern":"flaky"}},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":2}},
      {"id":"cl-t4","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":8,
       "content":{"toolName":"Workflow"},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":3}},
      {"id":"cl-t5","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":9,
       "content":{"toolName":"ExitPlanMode"},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":4}},
      {"id":"cl-t6","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":10,
       "content":{"toolName":"AskUserQuestion"},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":5}},
      {"id":"cl-t7","sessionId":"gate-claude","type":"tool","status":"done","orderSeq":11,
       "content":{"toolName":"SomeFutureTool"},
       "source":{"nativeMessageId":"cl-msg-1","blockIndex":6}},
      {"id":"cl-r1","sessionId":"gate-claude","type":"reasoning","status":"done","orderSeq":4,
       "content":{"kind":"reasoning","rawText":"Checking the package layout."},
       "source":{"itemId":"cl-msg-1"}}
    ]
    """#

    /// Codex: the observed table (`apply_patch`, `shell` via wire kind
    /// `command`, `web_search`), the product-level `request_user_input` skip,
    /// an unknown name, and `Workflow` kept as a plain call because Codex has
    /// no special table.
    private static let codexFixtureJSON = #"""
    [
      {"id":"cx-m1","sessionId":"gate-codex","type":"message","status":"done","role":"assistant","orderSeq":3,
       "content":{"text":"Applied the patch and re-ran the suite."},
       "source":{"itemId":"cx-msg-1"}},
      {"id":"cx-t1","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":5,
       "content":{"toolName":"apply_patch","kind":"mcp","input":{"path":"/repo/App.swift"}},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":0}},
      {"id":"cx-t2","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":6,
       "content":{"toolName":"shell","kind":"command","input":{"command":["swift","test"]}},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":1}},
      {"id":"cx-t3","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":7,
       "content":{"toolName":"web_search","kind":"web_search","input":{"query":"swift testing"}},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":2}},
      {"id":"cx-t4","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":8,
       "content":{"toolName":"request_user_input"},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":3}},
      {"id":"cx-t5","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":9,
       "content":{"toolName":"SomeFutureTool"},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":4}},
      {"id":"cx-t6","sessionId":"gate-codex","type":"tool","status":"done","orderSeq":10,
       "content":{"toolName":"Workflow"},
       "source":{"nativeMessageId":"cx-msg-1","blockIndex":5}},
      {"id":"cx-r1","sessionId":"gate-codex","type":"reasoning","status":"done","orderSeq":4,
       "content":{"kind":"reasoning","rawText":"Reading the failing test output."},
       "source":{"itemId":"cx-msg-1"}}
    ]
    """#

    /// DSH: its own table (`bash`, `web_search`, `str_replace_editor`,
    /// `subagent`), an unknown name, and `ExitPlanMode` kept as a plain `.plan`
    /// call — DSH has no skip table, so the Claude rule must not leak.
    private static let dshFixtureJSON = #"""
    [
      {"id":"dsh-m1","sessionId":"gate-dsh","type":"message","status":"done","role":"assistant","orderSeq":3,
       "content":{"text":"The editor applied the replacement and the agent finished."},
       "source":{"itemId":"dsh-msg-1"}},
      {"id":"dsh-t1","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":5,
       "content":{"toolName":"bash","input":{"command":"npm test"}},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":0}},
      {"id":"dsh-t2","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":6,
       "content":{"toolName":"web_search","input":{"query":"dsh bridge tools"}},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":1}},
      {"id":"dsh-t3","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":7,
       "content":{"toolName":"str_replace_editor","input":{"path":"/repo/tools.ts"}},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":2}},
      {"id":"dsh-t4","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":8,
       "content":{"toolName":"subagent","input":{"prompt":"inspect history"}},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":3}},
      {"id":"dsh-t5","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":9,
       "content":{"toolName":"SomeFutureTool"},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":4}},
      {"id":"dsh-t6","sessionId":"gate-dsh","type":"tool","status":"done","orderSeq":10,
       "content":{"toolName":"ExitPlanMode"},
       "source":{"nativeMessageId":"dsh-msg-1","blockIndex":5}},
      {"id":"dsh-r1","sessionId":"gate-dsh","type":"reasoning","status":"done","orderSeq":4,
       "content":{"kind":"reasoning","rawText":"Checking the bridge history projection."},
       "source":{"itemId":"dsh-msg-1"}}
    ]
    """#

    /// The on-screen fixture: a user bubble, a settled reasoning item (the
    /// persistent `思考过程` row), a Markdown body and a collapsed tool span
    /// with a diff badge plus the Workflow special card. A running reasoning
    /// row belongs to the live working line, not this row — see
    /// `runningReasoningJSON` for its negative assertion.
    private static let viewFixtureJSON = #"""
    [
      {"id":"v-u1","sessionId":"gate-views","type":"message","status":"done","role":"user","orderSeq":1,
       "content":{"text":"The flaky test is back. Can you take a look?"},
       "source":{"itemId":"gate-user-msg"}},
      {"id":"v-m1","sessionId":"gate-views","type":"message","status":"done","role":"assistant","orderSeq":2,
       "content":{"text":"Found the race in `TimelineTests.swift`.\n\nThe driver now waits for the row to settle before it asserts."},
       "source":{"itemId":"gate-msg"}},
      {"id":"v-t1","sessionId":"gate-views","type":"tool","status":"done","orderSeq":3,
       "content":{"toolName":"Read","input":{"file_path":"/repo/Tests/TimelineTests.swift"}},
       "source":{"nativeMessageId":"gate-msg","blockIndex":0}},
      {"id":"v-t2","sessionId":"gate-views","type":"tool","status":"done","orderSeq":4,
       "content":{"toolName":"Bash","input":{"command":"swift test --filter TimelineTests"}},
       "source":{"nativeMessageId":"gate-msg","blockIndex":1}},
      {"id":"v-t3","sessionId":"gate-views","type":"tool","status":"done","orderSeq":5,
       "content":{"toolName":"Edit","input":{"file_path":"/repo/Tests/TimelineTests.swift"},
                  "output":{"lineStat":{"addedLineCount":2,"removedLineCount":1}}},
       "source":{"nativeMessageId":"gate-msg","blockIndex":2}},
      {"id":"v-t4","sessionId":"gate-views","type":"tool","status":"done","orderSeq":6,
       "content":{"toolName":"Workflow"},
       "source":{"nativeMessageId":"gate-msg","blockIndex":3}},
      {"id":"v-r1","sessionId":"gate-views","type":"reasoning","status":"done","orderSeq":7,
       "content":{"kind":"reasoning","rawText":"Inspecting the test harness."},
       "source":{"itemId":"gate-msg"}}
    ]
    """#

    /// Layer 2's fixture: a Read whose body is the 24K / 298-line result that
    /// rendered blank on the device. The output string is escaped by
    /// `JSONSerialization`, so the fixture stays one JSON document.
    private static func detailCallJSON(output: String) -> String {
        let outputJSON = jsonString(output)
        return #"""
        {"id":"detail-read","sessionId":"gate-detail","type":"tool","status":"done","orderSeq":1,
         "content":{"toolName":"Read","input":{"file_path":"/repo/Sources/Feature/Generated.swift"},
           "output":\#(outputJSON)},
         "source":{"itemId":"detail-read"}}
        """#
    }

    /// Layer 1's group-page fixture: one settled reasoning row and three tool
    /// rows of one message, exactly the `[thinkingContent, toolCalls]` span
    /// shape the builder emits. `prepareViews` runs it through
    /// `CodeMessageBuilder`; the reasoning row must not reach the page, which
    /// carries the call list only (pp device report 2026-10-29).
    private static let detailGroupJSON = #"""
    [
      {"id":"dg-r1","sessionId":"gate-group","type":"reasoning","status":"done","orderSeq":1,
       "content":{"kind":"reasoning","rawText":"Inspecting both files before the edit."},
       "source":{"itemId":"dg-msg"}},
      {"id":"dg-t1","sessionId":"gate-group","type":"tool","status":"done","orderSeq":2,
       "content":{"toolName":"Edit","input":{"file_path":"/repo/Main.dc.html"},
                  "output":{"lineStat":{"addedLineCount":2,"removedLineCount":1}}},
       "source":{"nativeMessageId":"dg-msg","blockIndex":0}},
      {"id":"dg-t2","sessionId":"gate-group","type":"tool","status":"done","orderSeq":3,
       "content":{"toolName":"Edit","input":{"file_path":"/repo/Main.dc.html"}},
       "source":{"nativeMessageId":"dg-msg","blockIndex":1}},
      {"id":"dg-t3","sessionId":"gate-group","type":"tool","status":"done","orderSeq":4,
       "content":{"toolName":"Edit","input":{"file_path":"/repo/Dark.dc.html"}},
       "source":{"nativeMessageId":"dg-msg","blockIndex":2}}
    ]
    """#

    /// A running reasoning row beside a settled body: the persistent block
    /// must not be created from it.
    private static let runningReasoningJSON = #"""
    [
      {"id":"run-r1","sessionId":"gate-reasoning","type":"reasoning","status":"running","orderSeq":1,
       "content":{"kind":"reasoning","rawText":"Still streaming."},
       "source":{"itemId":"gate-reasoning-msg"}},
      {"id":"run-m1","sessionId":"gate-reasoning","type":"message","status":"done","role":"assistant","orderSeq":2,
       "content":{"text":"The settled answer."},
       "source":{"itemId":"gate-reasoning-msg"}}
    ]
    """#

    /// The 24K / ~298-line Read result used by both the height leg and the
    /// rendered detail screenshot.
    private static var longReadOutputText: String {
        let rowFormat = #"{"index":%d,"path":"Sources/Feature/F%04d/Generated.swift","status":"ok","message":"row %d of the long read fixture"}"#
        return (1...298).map { String(format: rowFormat, $0, $0, $0) }
            .joined(separator: "\n")
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    private static let textOutputJSON = #"""
    {"id":"out-text","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"Bash","output":"hello from bash"},
     "source":{"itemId":"out-text"}}
    """#

    private static let todosOutputJSON = #"""
    {"id":"out-todos","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"TodoWrite","input":{"todos":[
       {"content":"Inspect the failing test","status":"completed"},
       {"content":"Patch the reducer","status":"in_progress"},
       {"content":"Run the Code gate","status":"pending"}
     ]}},
     "source":{"itemId":"out-todos"}}
    """#

    private static let diffOutputJSON = #"""
    {"id":"out-diff","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"Edit","output":"--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same"},
     "source":{"itemId":"out-diff"}}
    """#

    private static let answersOutputJSON = #"""
    {"id":"out-answers","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"AskUserQuestion","output":{"submittedAnswers":[
       {"question":"Which file?","answer":"TimelineTests.swift"}
     ]}},
     "source":{"itemId":"out-answers"}}
    """#

    private static let planOutputJSON = #"""
    {"id":"out-plan","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"ExitPlanMode","output":{"kind":"approved_plan"}},
     "source":{"itemId":"out-plan"}}
    """#

    /// An Edit call whose only payload is its input. The detail page used to
    /// render these four fields as an "Answers" section (device report
    /// 2026-10-23).
    private static let editInputOutputJSON = #"""
    {"id":"out-edit-input","sessionId":"gate-output","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"Edit","input":{"file_path":"/tmp/MEMORY.md",
       "old_string":"a","new_string":"b","replace_all":false}},
     "source":{"itemId":"out-edit-input"}}
    """#

    /// Row-height matrix fixtures. Pure-tool messages carry only tool rows, so
    /// the builder groups them into one `.system` row; the text fixtures use
    /// intentional Markdown hard line breaks (two trailing spaces + newline).
    private enum RowHeightFixtureJSON {
        static let toolOne = #"""
        [
          {"id":"h-t1","sessionId":"gate-height","type":"tool","status":"done","orderSeq":1,
           "content":{"toolName":"Read","input":{"file_path":"/repo/Sources/App.swift"}},
           "source":{"nativeMessageId":"gate-tool-one","blockIndex":0}}
        ]
        """#

        /// span(Read), special(Workflow), span(Bash): three collapsed rows in
        /// one `toolCalls` block.
        static let toolThree = #"""
        [
          {"id":"h-t1","sessionId":"gate-height","type":"tool","status":"done","orderSeq":1,
           "content":{"toolName":"Read","input":{"file_path":"/repo/Sources/App.swift"}},
           "source":{"nativeMessageId":"gate-tool-three","blockIndex":0}},
          {"id":"h-t2","sessionId":"gate-height","type":"tool","status":"done","orderSeq":2,
           "content":{"toolName":"Workflow"},
           "source":{"nativeMessageId":"gate-tool-three","blockIndex":1}},
          {"id":"h-t3","sessionId":"gate-height","type":"tool","status":"done","orderSeq":3,
           "content":{"toolName":"Bash","input":{"command":"swift test --filter TimelineTests"}},
           "source":{"nativeMessageId":"gate-tool-three","blockIndex":2}}
        ]
        """#

        static let cjk = #"""
        [
          {"id":"h-cjk","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"第一行：这是一个用于验证 Code 页行高测量的长中文段落，包含全角标点、括号（以及中文引号「测试」）。  \n第二行：两个尾随空格形成硬换行，内容仍然很长，用来触发多次折行，测量引擎必须按字符边界处理，不能按空格分词。  \n第三行：继续追加中文内容，确保这一行在两种宽度下都会折行，并且和上一行之间没有空行。  \n最后一行：完成。"},
           "source":{"itemId":"gate-cjk"}}
        ]
        """#

        static let emoji = #"""
        [
          {"id":"h-emoji","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"第一行 😀🚀🎯 混合 emoji：👨‍👩‍👧‍👦 家庭、🇨🇳🇺🇸 旗帜、🧑🏽‍💻 职业。  \n第二行：连续 emoji 😀😀😀😀😀😀😀😀😀😀 与 CJK 混排，宽度必须按字素簇计算。  \n第三行：结束。"},
           "source":{"itemId":"gate-emoji"}}
        ]
        """#

        static let bubble = #"""
        [
          {"id":"h-bubble","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"请检查这个中文用户气泡的高度：第一行比较长，包含标点和 emoji 😀🚀🎯，第二行继续说明为什么气泡在两种宽度下都必须与测量值一致。"},
           "source":{"itemId":"gate-bubble"}}
        ]
        """#

        /// Text bubble + one image (4:3, so the large box is 200x150) + one
        /// PDF (official file card: 140x140 square). The attachments are
        /// sibling blocks
        /// after the bubble.
        static let bubbleAttachment = #"""
        [
          {"id":"h-ba","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"Please check the attached screenshot and the report.",
             "attachments":[
               {"fileId":"gate-ba-img","name":"screen.png","mediaType":"image/png","size":2048,"width":400,"height":300},
               {"fileId":"gate-ba-doc","name":"report.pdf","mediaType":"application/pdf","size":4096}
             ]},
           "source":{"itemId":"gate-bubble-attachment"}}
        ]
        """#

        /// No text: the official `UserTextBubble` is not instantiated, so the
        /// image grid alone keeps the row alive.
        static let bubblePureAttachment = #"""
        [
          {"id":"h-bpa","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"",
             "attachments":[
               {"fileId":"gate-bpa-img","name":"photo.png","mediaType":"image/png","size":2048,"width":400,"height":300}
             ]},
           "source":{"itemId":"gate-bubble-pure-attachment"}}
        ]
        """#

        /// No text and one file: the official 140 pt square file card.
        static let bubbleFileOnly = #"""
        [
          {"id":"h-bfo","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"",
             "attachments":[
               {"fileId":"gate-bfo-doc","name":"report.pdf","mediaType":"application/pdf","size":4096}
             ]},
           "source":{"itemId":"gate-bubble-file-only"}}
        ]
        """#

        /// Three images: the wide tile on top, two squares below.
        static let bubbleThreeImages = #"""
        [
          {"id":"h-b3","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"Three shots:",
             "attachments":[
               {"fileId":"gate-b3-1","name":"one.png","mediaType":"image/png","size":1024,"width":400,"height":300},
               {"fileId":"gate-b3-2","name":"two.png","mediaType":"image/png","size":1024,"width":300,"height":400},
               {"fileId":"gate-b3-3","name":"three.png","mediaType":"image/png","size":1024,"width":800,"height":600}
             ]},
           "source":{"itemId":"gate-bubble-three-images"}}
        ]
        """#

        /// Five images: the fourth square carries `+1`; the grid stays two
        /// square rows tall.
        static let bubbleFiveImages = #"""
        [
          {"id":"h-b5","sessionId":"gate-height","type":"message","status":"done","role":"user","orderSeq":1,
           "content":{"text":"Five:",
             "attachments":[
               {"fileId":"gate-b5-1","name":"one.png","mediaType":"image/png","size":1024,"width":400,"height":300},
               {"fileId":"gate-b5-2","name":"two.png","mediaType":"image/png","size":1024,"width":300,"height":400},
               {"fileId":"gate-b5-3","name":"three.png","mediaType":"image/png","size":1024,"width":800,"height":600},
               {"fileId":"gate-b5-4","name":"four.png","mediaType":"image/png","size":1024,"width":400,"height":400},
               {"fileId":"gate-b5-5","name":"five.png","mediaType":"image/png","size":1024,"width":400,"height":400}
             ]},
           "source":{"itemId":"gate-bubble-five-images"}}
        ]
        """#

        /// Two text bodies and one collapsed tool call under the same native
        /// message id: the builder stacks text, text, then `toolCalls`, so the
        /// row pays two inter-block gaps and one Dynamic Type-scaled tool line
        /// box. This is the fixture that keeps the inter-block gap honest
        /// between the view and `CodeMessageHeightMeasurer`.
        static let multiBlock = #"""
        [
          {"id":"h-mb-1","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"The first paragraph of one message."},
           "source":{"nativeMessageId":"gate-multi","blockIndex":0}},
          {"id":"h-mb-2","sessionId":"gate-height","type":"tool","status":"done","orderSeq":2,
           "content":{"toolName":"Read","input":{"file_path":"/repo/Sources/App.swift"}},
           "source":{"nativeMessageId":"gate-multi","blockIndex":1}},
          {"id":"h-mb-3","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":3,
           "content":{"text":"The second paragraph after the tool row."},
           "source":{"nativeMessageId":"gate-multi","blockIndex":2}}
        ]
        """#

        /// One fenced code block. The card's header height is a Dynamic Type
        /// ScaledMetric, so at the accessibility size the measured document
        /// and the drawn card must agree on the taller header.
        static let codeCard = #"""
        [
          {"id":"h-card","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"Fixed it:\n\n```swift\nfunc settle() async {\n    await clock.advance(by: .milliseconds(120))\n}\n```"},
           "source":{"itemId":"gate-code-card"}}
        ]
        """#

        /// A settled thinking block in the same message as the answer, so the
        /// row pays the thinking line box, one inter-block gap and the text.
        static let thinking = #"""
        [
          {"id":"h-th-1","sessionId":"gate-height","type":"reasoning","status":"done","orderSeq":1,
           "content":{"kind":"reasoning","rawText":"Checked the driver and the failing assertion."},
           "source":{"nativeMessageId":"gate-thinking","blockIndex":0}},
          {"id":"h-th-2","sessionId":"gate-height","type":"message","status":"done","role":"assistant","orderSeq":2,
           "content":{"text":"The race is in the driver."},
           "source":{"nativeMessageId":"gate-thinking","blockIndex":1}}
        ]
        """#
    }

    /// Fixtures for the renderer-measurement leg. The short body isolates the
    /// plain text layout; the code/table body exercises the fenced-code and
    /// table leaves, where the structural measurer and the SwiftUI renderer
    /// disagreed by 3 pt and 1900 pt on the device probe.
    private enum RendererMeasureFixtureJSON {
        static let short = #"""
        [
          {"id":"h-short","sessionId":"gate-renderer","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"Fixed the flaky test."},
           "source":{"itemId":"gate-short"}}
        ]
        """#

        static let codeTable = #"""
        [
          {"id":"h-code-table","sessionId":"gate-renderer","type":"message","status":"done","role":"assistant","orderSeq":1,
           "content":{"text":"The driver now waits for the row to settle:\n\n```swift\nfunc waitUntilSettled() async {\n    await clock.advance(by: .milliseconds(120))\n}\n```\n\n| Case | Height |\n| --- | --- |\n| short | 56 |\n| long | 610 |"},
           "source":{"itemId":"gate-code-table"}}
        ]
        """#
    }
}

/// Only reachable through the launch argument; the product root is untouched.
struct CodeProfileAutoRunRootView: View {
    @State private var model = CodeProfileAutoRunModel()

    var body: some View {
        Group {
            switch model.stage {
            case .idle:
                Color(.systemBackground)
            case .messageRow:
                if let group = model.messageGroup {
                    messageStage(group)
                } else {
                    Color(.systemBackground)
                }
            case .detail:
                if let call = model.detailCall {
                    CodeToolDetailView(call: call)
                } else {
                    Color(.systemBackground)
                }
            case .detailGroup:
                if !model.detailGroupCalls.isEmpty {
                    CodeToolGroupDetailView(calls: model.detailGroupCalls,
                                            cwd: "/repo")
                } else {
                    Color(.systemBackground)
                }
            case .workingMark:
                workingMarkStage
            case .thinkingStatus:
                thinkingStatusStage
            case .scrollDown:
                if let group = model.messageGroup {
                    scrollDownStage(group)
                } else {
                    Color(.systemBackground)
                }
            case .collapsedRows, .collapsedRowsDark:
                collapsedRowsStage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deterministic captures: every stage is light except the dedicated
        // dark row gallery, which renders the same tree under dark tokens.
        .preferredColorScheme(model.stage == .collapsedRowsDark ? .dark : .light)
        .task { await model.run() }
    }

    /// The R28 acceptance gallery: one row per state, exactly the fixtures
    /// the height leg hosts. 16 pt margins / page background match the Code
    /// transcript so the screenshot is comparable with the official one.
    private var collapsedRowsStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rowGallery) { item in
                    item.rowView()
                }
            }
            .padding(.horizontal, CodePageTheme.rowMarginLeading)
            .padding(.vertical, 20)
        }
        // The official Code page background (#F9F9F7 / #151515), so the
        // gallery's token comparison includes the surface behind the rows.
        // `preferredColorScheme` alone is a presentation preference and the
        // app root's own `.preferredColorScheme` can win over it, which left
        // the b643 dark gallery with dark background but light-mode tokens.
        // The explicit environment override is what the row views read.
        .background(model.stage == .collapsedRowsDark
                    ? CodePageTheme.pageBackgroundColor.dark
                    : CodePageTheme.pageBackgroundColor.light)
        .environment(\.colorScheme,
                     model.stage == .collapsedRowsDark ? .dark : .light)
    }

    private func messageStage(_ group: ChatTimelineGroup) -> some View {
        ScrollView {
            // The fixture is a message row on its own; the live turn's
            // working status is the separate `CodeWorkingStatusRow`.
            CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo")
                .padding(.horizontal, CodePageTheme.rowMarginLeading)
                .padding(.vertical, 20)
        }
        .background(Color(.systemBackground))
    }

    /// The return control over the real Code row. The product page places it
    /// centred above the composer; the gate has no composer, so it sits at the
    /// same bottom edge and the screenshot shows the control's actual size and
    /// chrome.
    @MainActor
    private func scrollDownStage(_ group: ChatTimelineGroup) -> some View {
        let state = CodeScrollDownIndicatorState(isVisible: true)
        return ZStack(alignment: .bottom) {
            ScrollView {
                CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo")
                    .padding(.horizontal, CodePageTheme.rowMarginLeading)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            CodeScrollDownIndicator(state: state, onTap: {})
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    private var workingMarkStage: some View {
        VStack(spacing: 16) {
            WorkingMarkView(body: .think, isRunning: true, reduceMotion: true)
            Text(verbatim: "Computing...")
                .font(.system(size: CodePageTheme.runningStatusFontSize))
                .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: .light))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// The three working-row texts side by side: the ≥60 s thinking tier,
    /// the closed duration (inside its 2 s window), and the verb fallback.
    private var thinkingStatusStage: some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 10) {
            CodeThinkingStatusLine(
                phase: .thinking(startedAt: now.addingTimeInterval(-63)))
            CodeThinkingStatusLine(
                phase: .thoughtFor(seconds: 63,
                                   endedAt: now,
                                   fallbackStartedAt: now.addingTimeInterval(-63)))
            CodeThinkingStatusLine(
                phase: .working(startedAt: now))
        }
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
#endif
