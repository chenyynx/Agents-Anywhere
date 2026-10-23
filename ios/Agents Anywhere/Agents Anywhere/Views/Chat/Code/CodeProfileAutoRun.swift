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
//                               running reasoning line and collapsed tool rows
//   - code-detail.png         — CodeToolDetailView (diff output + following call)
//   - code-working-mark.png   — the 20 pt working mark beside its status text
//
// `completed` is only true in the final write. Every earlier phase writes a
// checkpoint with `completed: false`, so a crash mid-gate still leaves the last
// finished phase and its assertions on disk for the CI assertion step.

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
        case workingMark
    }

    private(set) var stage: Stage = .idle
    private(set) var messageGroup: ChatTimelineGroup?
    private(set) var detailCall: CodeToolCall?
    private(set) var detailFollowing: [CodeToolCall] = []

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

        await captureViews()
        finish()
    }

    // MARK: - Runtime fixtures

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
            case let .reasoning(id, _): return "reasoning:\(id)"
            case let .text(id, _): return "text:\(id)"
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
        let firstEight = (1...8).map { "w\($0)" }.joined(separator: " ") + " "
        let firstSixteen = (1...16).map { "w\($0)" }.joined(separator: " ") + " "
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
        check(blocked == nil, "streaming: a chunk published inside the 0.1 s window")
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

        // Chunk size: a burst is split into at most eight words per publish.
        var chunker = seededPublisher()
        let chunkFirst = chunker.receive(delta: burst, at: 0.1)
        check(chunkFirst?.text == "seed " + firstEight,
              "streaming: first chunk \(chunkFirst?.text ?? "nil")")
        let chunkSecond = chunker.flush(at: 0.2 + epsilon)
        check(chunkSecond?.text == "seed " + firstSixteen,
              "streaming: second chunk \(chunkSecond?.text ?? "nil")")
        let chunkThird = chunker.flush(at: 0.3 + epsilon)
        check(chunkThird?.text == "seed " + burst,
              "streaming: final chunk \(chunkThird?.text ?? "nil")")
        streaming["chunks"] = [
            "first": chunkFirst?.text ?? "",
            "second": chunkSecond?.text ?? "",
            "third": chunkThird?.text ?? "",
        ] as [String: Any]

        // Chinese fallback: no word boundaries, so characters are counted.
        var cjk = seededPublisher()
        let cjkFirst = cjk.receive(delta: chinese, at: 0.1)
        check(cjkFirst?.text == "seed " + String(repeating: "你", count: 16),
              "streaming: Chinese first chunk \(cjkFirst?.text ?? "nil")")
        let cjkRest = cjk.flush(at: 0.2 + epsilon)
        check(cjkRest?.text == "seed " + chinese,
              "streaming: Chinese rest \(cjkRest?.text ?? "nil")")
        streaming["chinese"] = [
            "first": cjkFirst?.text ?? "",
            "rest": cjkRest?.text ?? "",
        ] as [String: Any]

        // Catch-up: the first snapshot and an oversized backlog publish whole.
        var catchUp = CodeStreamingPublisher()
        let catchUpFirst = catchUp.receive(delta: backlog, at: 0)
        check(catchUpFirst?.text == backlog,
              "streaming: the first snapshot did not publish the whole backlog")
        var catchUpAfterSeed = seededPublisher()
        let catchUpBacklog = catchUpAfterSeed.receive(delta: backlog, at: 0.1)
        check(catchUpBacklog?.text == "seed " + backlog,
              "streaming: an oversized backlog was paced instead of caught up")
        streaming["catchUp"] = [
            "first": catchUpFirst?.text ?? "",
            "afterSeed": catchUpBacklog?.text ?? "",
        ] as [String: Any]

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
        report["toolLabels"] = ["text": text,
                                "singleShape": singleShape,
                                "wrongCount": wrongCount]
    }

    // MARK: - Views and screenshots

    private func captureViews() async {
        prepareViews()
        await verifyMessageRowHeight()

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
            views["detail"] = capture("code-detail.png")
        } else {
            failures.append("views: tool detail fixture unavailable")
        }
        report["views"] = views
        persist(phase: "views.detail")

        stage = .workingMark
        await wait(500)
        views["workingMark"] = capture("code-working-mark.png")
        report["views"] = views
        persist(phase: "views.workingMark")
    }

    private func prepareViews() {
        guard !didPrepareViews else { return }
        didPrepareViews = true

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

        let rows = items.map { ChatTimelineRowModel($0) }
        messageGroup = ChatTimelineGroup(kind: .single, rows: rows,
                                         explicitID: "gate-code-thread")

        guard let detailItem = Self.decodeItem(Self.detailCallJSON) else {
            failures.append("views: detail call JSON did not decode")
            return
        }
        detailCall = CodeToolCall(item: detailItem, kind: .edit)
        let detailOutput = CodeToolOutput(item: detailItem, kind: .edit)
        if case let .diff(diff) = detailOutput {
            check(diff.added == 2 && diff.removed == 1,
                  "views: detail diff +\(diff.added)/-\(diff.removed), expected +2/-1")
        } else {
            failures.append("views: detail call parsed as \(Self.describe(detailOutput)), expected a diff")
        }
        if let followingItem = Self.decodeItem(Self.followingCallJSON) {
            detailFollowing = [CodeToolCall(item: followingItem, kind: .bash)]
        }
        check(!detailFollowing.isEmpty,
              "views: detail fixture has no following call")
    }

    /// The exact height the controller stores before apply must equal the
    /// height the hosting row actually lays out at, or the row will correct
    /// itself when it first becomes visible — the movement the device probe
    /// caught. Render the same fixture offscreen, wait for ChatMarkdownView's
    /// parse, and compare.
    private func verifyMessageRowHeight() async {
        guard let group = messageGroup, let window = keyWindow else { return }
        let rowWidth = window.bounds.width - 2 * CodePageTheme.rowMarginLeading
        let host = UIHostingController(rootView:
            CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo",
                               showsWorkingStatus: true)
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
        // off the window: the row inside the timeline has no window inset.
        host.view.removeFromSuperview()
        host.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 200)
        host.view.layoutIfNeeded()
        let rendered = host.sizeThatFits(in: CGSize(
            width: window.bounds.width, height: .greatestFiniteMagnitude)).height

        let typography = TimelineChatContentAdapter.typography(
            dynamicType: String(describing: DynamicTypeSize.large),
            layoutDirection: 0,
            boldText: false)
        let measured = CodeMessageHeightMeasurer.height(
            group: group, profile: .claudeCode, showsWorkingStatus: true,
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

    /// Captures the app window. The stage view fills it, so the PNG shows the
    /// component at its real width and Dynamic Type, with the same chrome the
    /// simulator run has (status bar, background).
    private func capture(_ name: String) -> [String: Any] {
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
        return [
            "bytes": data.count,
            "width": Double(image.size.width),
            "height": Double(image.size.height),
            "distinctColors": sampledColors,
        ] as [String: Any]
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
      {"id":"cl-r1","sessionId":"gate-claude","type":"reasoning","status":"running","orderSeq":4,
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
      {"id":"cx-r1","sessionId":"gate-codex","type":"reasoning","status":"running","orderSeq":4,
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
      {"id":"dsh-r1","sessionId":"gate-dsh","type":"reasoning","status":"running","orderSeq":4,
       "content":{"kind":"reasoning","rawText":"Checking the bridge history projection."},
       "source":{"itemId":"dsh-msg-1"}}
    ]
    """#

    /// The on-screen fixture: a user bubble, a running reasoning row (the
    /// working status line), a Markdown body and a collapsed tool span with a
    /// diff badge plus the Workflow special card.
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
      {"id":"v-r1","sessionId":"gate-views","type":"reasoning","status":"running","orderSeq":7,
       "content":{"kind":"reasoning","rawText":"Inspecting the test harness."},
       "source":{"itemId":"gate-msg"}}
    ]
    """#

    private static let detailCallJSON = #"""
    {"id":"detail-edit","sessionId":"gate-detail","type":"tool","status":"done","orderSeq":1,
     "content":{"toolName":"Edit","input":{"file_path":"/repo/Tests/TimelineTests.swift"},
       "output":{"kind":"diff","lines":[
         {"type":"hunk","content":"@@ -1,4 +1,5 @@"},
         {"type":"normal","content":"let driver = TimelineDriver()","oldLineNumber":1,"newLineNumber":1},
         {"type":"remove","content":"await driver.start()","oldLineNumber":2},
         {"type":"add","content":"await driver.waitUntilSettled()","newLineNumber":2},
         {"type":"add","content":"await driver.assertNoOverlap()","newLineNumber":3},
         {"type":"normal","content":"await driver.finish()","oldLineNumber":3,"newLineNumber":4}
       ],"lineStat":{"addedLineCount":2,"removedLineCount":1}}},
     "source":{"itemId":"detail-edit"}}
    """#

    private static let followingCallJSON = #"""
    {"id":"detail-following","sessionId":"gate-detail","type":"tool","status":"done","orderSeq":2,
     "content":{"toolName":"Bash","input":{"command":"swift test --filter TimelineTests"}},
     "source":{"nativeMessageId":"detail-edit","blockIndex":1}}
    """#

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
                    CodeToolDetailView(call: call, followingCalls: model.detailFollowing)
                } else {
                    Color(.systemBackground)
                }
            case .workingMark:
                workingMarkStage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deterministic captures: the gate always renders the light appearance.
        .preferredColorScheme(.light)
        .task { await model.run() }
    }

    private func messageStage(_ group: ChatTimelineGroup) -> some View {
        ScrollView {
            // The fixture is a live turn: its last message owns the single
            // working status line, exactly as the adapter assigns it.
            CodeMessageRowView(group: group, profile: .claudeCode, cwd: "/repo",
                               showsWorkingStatus: true)
                .padding(.horizontal, CodePageTheme.rowMarginLeading)
                .padding(.vertical, 20)
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
}
#endif
