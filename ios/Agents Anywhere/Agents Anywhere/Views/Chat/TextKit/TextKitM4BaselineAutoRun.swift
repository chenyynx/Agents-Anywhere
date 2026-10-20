#if DEBUG
import QuartzCore
import SwiftUI
import UIKit

/// C5/M4 baseline probe. It measures the four costs that decide whether the
/// streaming row can move to the TextKit cell:
///
/// 1. the incremental parse the current SwiftUI streamer already runs
///    (`MarkdownStreamSplit` + `MarkdownParseState`, off the main actor);
/// 2. a full `AssistantMarkdownDocumentParser.make` per batch, which is what a
///    naive "open the streaming gate now" change would do;
/// 3. a full TextKit measurement of that document per batch;
/// 4. a full `AssistantMarkdownCell` rebuild per batch.
///
/// The probe writes numbers only. It never changes a row, a view or a height,
/// and it fails only when the probe itself cannot finish. The scenario with an
/// unterminated code fence is the worst case: the safe split finds no boundary,
/// so the whole text becomes the tail on every batch.
@MainActor
enum TextKitM4BaselineAutoRun {
    static let launchArgument = "aa-textkit-m4-baseline"
    static let resultFileName = "textkit-m4-baseline.json"

    /// AA's streaming reveal cadence (`ReplyPresentation.revealSeconds` plus
    /// one frame). Used only to turn the totals into a duty cycle.
    private static let cadenceMilliseconds: Double = 260
    private static let columnWidth: CGFloat = 388

    private struct Scenario {
        let name: String
        let text: String
        let batches: Int
    }

    static func run() async {
        let scale = max(1, UITraitCollection.current.displayScale)
        let typography = TimelineChatContentAdapter.typography(
            dynamicType: "UICTContentSizeCategoryL",
            layoutDirection: 0,
            boldText: false)
        let scenarios = makeScenarios()
        var report: [String: Any] = [
            "completed": false,
            "method": "simulator DEBUG; off-main parse is measured as awaited wall time",
            "cadenceMs": cadenceMilliseconds,
            "width": Double(columnWidth),
            "displayScale": Double(scale),
        ]
        var failures: [String] = []
        var scenarioReports: [String: Any] = [:]

        for scenario in scenarios {
            let prefixes = prefixes(of: scenario.text, batches: scenario.batches)
            var state: MarkdownParseState?
            var tails: [String] = []
            var incrementalWall: [Double] = []
            var fullMake: [Double] = []
            var fullMeasure: [Double] = []
            var tailMake: [Double] = []
            var tailMeasure: [Double] = []
            var cellConfigure: [Double] = []
            var finalDocument: AssistantMarkdownDocument?
            var finalCellHeight: CGFloat = 0
            let builder = AssistantStreamingDocumentBuilder()
            var builderDurations: [Double] = []
            var builderDocument: AssistantStreamingDocument?
            var builderRejected = false

            let cell = AssistantMarkdownCell(frame: CGRect(
                x: 0, y: 0, width: columnWidth, height: 800))
            cell.contentView.frame = CGRect(
                x: 0, y: 0, width: columnWidth, height: 800)

            for (batchIndex, prefix) in prefixes.enumerated() {
                let parseStart = CACurrentMediaTime()
                let parsed: (blocks: [MarkdownBlockSnapshot], state: MarkdownParseState, tail: String)
                do {
                    parsed = try await parseIncrementally(prefix, previous: state)
                } catch {
                    failures.append("\(scenario.name) batch \(batchIndex): parse failed \(error)")
                    continue
                }
                incrementalWall.append((CACurrentMediaTime() - parseStart) * 1000)
                state = parsed.state
                tails.append(parsed.tail)

                let (streaming, builderMs) = time {
                    builder.make(text: prefix, typography: typography)
                }
                builderDurations.append(builderMs)
                if let streaming {
                    builderDocument = streaming
                } else {
                    builderRejected = true
                    failures.append("\(scenario.name) batch \(batchIndex): builder rejected")
                }

                let (document, makeMs) = time {
                    AssistantMarkdownDocumentParser.make(
                        text: prefix,
                        resolvesFileReferences: true,
                        typography: typography)
                }
                fullMake.append(makeMs)
                guard let document else {
                    failures.append("\(scenario.name) batch \(batchIndex): full document rejected")
                    continue
                }
                finalDocument = document

                let (measured, measureMs) = time {
                    AssistantMarkdownTextLayout.measure(
                        document, width: columnWidth, displayScale: scale)
                }
                fullMeasure.append(measureMs)
                if measured <= 0 {
                    failures.append("\(scenario.name) batch \(batchIndex): measured \(measured)")
                }

                let (tailDocument, tailMakeMs): (AssistantMarkdownDocument?, Double) = time {
                    parsed.tail.isEmpty ? nil : AssistantMarkdownDocumentParser.make(
                        text: parsed.tail,
                        resolvesFileReferences: true,
                        typography: typography)
                }
                tailMake.append(tailMakeMs)
                if !parsed.tail.isEmpty, tailDocument == nil {
                    failures.append("\(scenario.name) batch \(batchIndex): tail document rejected")
                }
                if let tailDocument {
                    tailMeasure.append(time {
                        AssistantMarkdownTextLayout.measure(
                            tailDocument, width: columnWidth, displayScale: scale)
                    }.1)
                }

                let (_, cellMs) = time {
                    cell.configure(document)
                    cell.layoutIfNeeded()
                }
                cellConfigure.append(cellMs)
                finalCellHeight = cell.contentView.systemLayoutSizeFitting(
                    CGSize(width: columnWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel).height
            }

            if let finalDocument {
                if finalCellHeight <= 0 {
                    failures.append("\(scenario.name): cell fitting reported \(finalCellHeight)")
                }
                let staticHeight = AssistantMarkdownTextLayout.measure(
                    finalDocument, width: columnWidth, displayScale: scale)
                var builderMatches = false
                var builderHeight: CGFloat = -1
                var builderBlockCount = -1
                if let builderDocument {
                    builderHeight = AssistantMarkdownTextLayout.measure(
                        builderDocument.document, width: columnWidth,
                        displayScale: scale)
                    builderBlockCount = builderDocument.document.blocks.count
                    builderMatches = builderBlockCount == finalDocument.blocks.count
                        && builderDocument.document.blockGroups == finalDocument.blockGroups
                        && builderDocument.document.plainTextLength
                            == finalDocument.plainTextLength
                        && abs(builderHeight - staticHeight) <= 0.5
                }
                if !builderMatches {
                    failures.append("\(scenario.name): builder document differs from the full parse")
                }
                var correctionGeneration = -1
                if let finalPrefix = prefixes.last {
                    let drop = min(40, finalPrefix.count)
                    let corrected = "Corrected intro.\n\n" + String(finalPrefix.dropFirst(drop))
                    if let correctedDocument = builder.make(
                        text: corrected, typography: typography) {
                        correctionGeneration = correctedDocument.generation
                        if correctedDocument.document.blocks.isEmpty {
                            failures.append("\(scenario.name): corrected document has no blocks")
                        }
                    } else {
                        failures.append("\(scenario.name): corrected text was rejected")
                    }
                }
                if correctionGeneration < 1 {
                    failures.append("\(scenario.name): correction did not bump the generation")
                }
                scenarioReports[scenario.name] = [
                    "batches": prefixes.count,
                    "textLength": prefixes.last?.utf8.count ?? 0,
                    "topLevelBlocks": finalDocument.blocks.count,
                    "blockCounts": finalDocument.blockCounts,
                    "tailLengths": tails.map { $0.utf8.count },
                    "finalCellHeight": Double(finalCellHeight),
                    "incrementalParseWall": stats(incrementalWall),
                    "fullMake": stats(fullMake),
                    "fullMeasure": stats(fullMeasure),
                    "tailMake": stats(tailMake),
                    "tailMeasure": stats(tailMeasure),
                    "cellConfigure": stats(cellConfigure),
                    "builder": stats(builderDurations),
                    "builderHeight": Double(builderHeight),
                    "builderBlockCount": builderBlockCount,
                    "builderMatchesStatic": builderMatches,
                    "builderRejected": builderRejected,
                    "correctionGeneration": correctionGeneration,
                    "dutyCycle": dutyCycle(
                        batches: prefixes.count,
                        incremental: incrementalWall,
                        fullMake: fullMake,
                        fullMeasure: fullMeasure,
                        cellConfigure: cellConfigure),
                ] as [String: Any]
            } else {
                failures.append("\(scenario.name): no final document")
            }
        }

        report["scenarios"] = scenarioReports
        report["failures"] = failures
        report["completed"] = true
        report["passed"] = failures.isEmpty
        report["device"] = UIDevice.current.name
        report["system"] = UIDevice.current.systemVersion

        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(resultFileName)
        try? data.write(to: url)
    }

    // MARK: - Fixtures

    private static func makeScenarios() -> [Scenario] {
        // The M3 fixture carries paragraphs, both list kinds, a quote, a code
        // block and a table; repeating it turns the stream into a realistic
        // long reply with safe boundaries throughout.
        let normal = Array(repeating: TextKitM3AutoRunModel.fixture, count: 4)
            .joined(separator: "\n\n")
        // Worst case: the stream never closes its fence, so `safeSplitIndex`
        // returns nil and every batch reparses the whole text.
        let code = (0..<160).map { "let value\($0) = \($0) * 2" }.joined(separator: "\n")
        let fence = "Streaming a long code block.\n\n```swift\n" + code + "\n"
        return [
            Scenario(name: "normal", text: normal, batches: 20),
            Scenario(name: "openFence", text: fence, batches: 12),
        ]
    }

    private static func prefixes(of text: String, batches: Int) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty, batches > 0 else { return [] }
        return (1...batches).map { index in
            String(characters[0..<(characters.count * index / batches)])
        }
    }

    // MARK: - Incremental parse (same pipeline as ChatMarkdownView)

    /// Mirrors `ChatMarkdownView.parse(_:previous:)`: completed blocks are
    /// parsed once, only the open tail is reparsed each batch.
    private static func parseIncrementally(_ text: String,
                                           previous: MarkdownParseState?) async throws
        -> (blocks: [MarkdownBlockSnapshot], state: MarkdownParseState, tail: String) {
        let worker = Task.detached(priority: .userInitiated) {
            try parseIncrementallySync(text, previous: previous)
        }
        return try await worker.value
    }

    private nonisolated static func parseIncrementallySync(
        _ text: String, previous: MarkdownParseState?
    ) throws -> (blocks: [MarkdownBlockSnapshot], state: MarkdownParseState, tail: String) {
        var state = previous.flatMap { $0.covers(text) ? $0 : nil } ?? MarkdownParseState()
        let consumed = state.prefixEnd(text)
        let split = MarkdownStreamSplit.safeSplitIndex(in: text)
            .flatMap { $0 >= consumed ? $0 : nil }
        if let split, split > consumed {
            let completed = try parse(String(text[consumed..<split]), startingAt: state.nextID)
            state.blocks.append(contentsOf: completed)
            state.nextID += completed.count
            state.prefixText = String(text[..<split])
        }
        let tail = String(text[(split ?? consumed)...])
        let tailBlocks = tail.isEmpty
            ? []
            : try parse(tail, startingAt: state.nextID)
        return (state.blocks + tailBlocks, state, tail)
    }

    private nonisolated static func parse(_ text: String,
                                          startingAt startID: Int) throws
        -> [MarkdownBlockSnapshot] {
        let snapshots = try AssistantMarkdownDocumentParser.parseBlocks(
            text: text, resolvesFileReferences: true)
        return snapshots.enumerated().map { offset, snapshot in
            MarkdownBlockSnapshot(id: startID + offset, content: snapshot.content)
        }
    }

    // MARK: - Metrics

    private static func time<T>(_ body: () -> T) -> (T, Double) {
        let start = CACurrentMediaTime()
        let value = body()
        return (value, (CACurrentMediaTime() - start) * 1000)
    }

    private static func stats(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        let total = sorted.reduce(0, +)
        return [
            "count": sorted.count,
            "minMs": sorted.first ?? 0,
            "medianMs": sorted[sorted.count / 2],
            "p95Ms": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))],
            "maxMs": sorted.last ?? 0,
            "totalMs": total,
        ]
    }

    /// Fraction of AA's batch budget each cost would consume if it ran on every
    /// batch. "naive" groups the full make + measure + cell rebuild; the
    /// incremental number is the parse alone.
    private static func dutyCycle(batches: Int,
                                  incremental: [Double],
                                  fullMake: [Double],
                                  fullMeasure: [Double],
                                  cellConfigure: [Double]) -> [String: Any] {
        let budget = Double(batches) * cadenceMilliseconds
        guard budget > 0 else { return [:] }
        let naive = fullMake.reduce(0, +) + fullMeasure.reduce(0, +)
            + cellConfigure.reduce(0, +)
        return [
            "incrementalParse": incremental.reduce(0, +) / budget,
            "fullMake": fullMake.reduce(0, +) / budget,
            "fullMeasure": fullMeasure.reduce(0, +) / budget,
            "cellConfigure": cellConfigure.reduce(0, +) / budget,
            "naiveTotal": naive / budget,
        ]
    }
}

/// Only reachable through the launch argument; the product root is untouched.
struct TextKitM4BaselineRootView: View {
    var body: some View {
        Text("M4 baseline")
            .task { await TextKitM4BaselineAutoRun.run() }
    }
}
#endif
