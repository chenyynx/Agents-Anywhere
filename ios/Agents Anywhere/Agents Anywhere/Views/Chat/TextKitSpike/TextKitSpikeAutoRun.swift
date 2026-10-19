#if DEBUG
import CDMarkdownKit
import Observation
import SwiftUI
import UIKit

/// C5 / M1 simulator spike. The app root swaps to this screen only when the
/// process is launched with `aa-textkit-spike`; the CI job boots a simulator,
/// reads `Documents/textkit-spike.json` and uploads it. This is a measurement
/// run, not a gate on product behaviour: it reports the height table and the
/// failure list the plan asks for.
@MainActor
@Observable
final class TextKitSpikeModel {
    static let launchArgument = "aa-textkit-spike"
    static let resultFileName = "textkit-spike.json"

    private(set) var statusLine = "starting"

    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var report: [String: Any] = [:]
    @ObservationIgnored private var didRun = false

    enum Kind {
        case pure, paragraphs, rich
    }

    private static let fixtures: [(name: String, text: String, kind: Kind)] = [
        ("pureParagraph", TextKitSpikeFixtures.pureParagraph, .pure),
        ("pureLatin", TextKitSpikeFixtures.pureLatin, .pure),
        ("pureCJK", TextKitSpikeFixtures.pureCJK, .pure),
        ("singleLineLatin", TextKitSpikeFixtures.singleLineLatin, .pure),
        ("singleLineCJK", TextKitSpikeFixtures.singleLineCJK, .pure),
        ("paragraphs3", TextKitSpikeFixtures.paragraphs3, .paragraphs),
        ("richLong", TextKitSpikeFixtures.richLong, .rich),
        ("tableOnly", TextKitSpikeFixtures.tableOnly, .rich),
        ("codeOnly", TextKitSpikeFixtures.codeOnly, .rich),
    ]

    func run() async {
        guard !didRun else { return }
        didRun = true
        statusLine = "waiting for the window"
        try? await Task.sleep(for: .milliseconds(900))

        guard let window = Self.keyWindow else {
            failures.append("spike: no key window")
            finish()
            return
        }

        let typography = TextKitSpikeTypography.current
        let width = floor(window.bounds.width - ChatMetrics.horizontalMargin * 2)
        report["device"] = UIDevice.current.name
        report["system"] = UIDevice.current.systemVersion
        report["scale"] = Double(window.screen.scale)
        report["windowSize"] = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
        report["width"] = Double(width)
        report["typography"] = [
            "body": Double(typography.bodySize),
            "lineSpacing": Double(typography.lineSpacing),
            "paragraphSpacing": Double(typography.paragraphSpacing),
            "fontLineHeight": Double(typography.font.lineHeight),
        ] as [String: Any]

        var rows: [[String: Any]] = []
        for fixture in Self.fixtures {
            statusLine = "measuring \(fixture.name)"

            let cdOutcome = await CDMarkdownProbe.measure(
                fixture.text, width: width, typography: typography)
            let cd = cdOutcome.0
            let cdAttributed = cdOutcome.1
            let tk2Same = Double(TextKit2Probe.height(of: cdAttributed, width: width))

            let product = await HostedMarkdownProbe.measure(
                fixture.text, width: width, in: window)

            var row: [String: Any] = [
                "name": fixture.name,
                "product": [
                    "height": Double(product.height),
                    "firstHeight": Double(product.firstHeight),
                    "settled": product.settled,
                    "samples": product.sampleCount,
                    "elapsedMs": Double(product.elapsedMilliseconds),
                ] as [String: Any],
                "cdmarkdown": [
                    "height": Double(cd.height),
                    "parseMs": Double(cd.parseMilliseconds),
                    "measureMs": Double(cd.measureMilliseconds),
                    "isTextKit2": cd.isTextKit2,
                    "lineFragmentPadding": Double(cd.lineFragmentPadding),
                    "insetTop": Double(cd.textContainerInset.top),
                    "insetBottom": Double(cd.textContainerInset.bottom),
                ] as [String: Any],
                "tk2SameAttributed": tk2Same,
                "cdVsTk2": abs(Double(cd.height) - tk2Same),
            ]

            if fixture.kind == .pure {
                let tk2Plain = Double(TextKit2Probe.height(
                    of: typography.plainAttributedString(fixture.text, paragraphSpacing: 0),
                    width: width))
                row["tk2Plain"] = tk2Plain
                row["productVsTk2Plain"] = abs(Double(product.height) - tk2Plain)
                row["productVsCD"] = abs(Double(product.height) - Double(cd.height))

                let bare = await HostedMarkdownProbe.measureBareText(
                    fixture.text, width: width, typography: typography, in: window)
                row["bareSwiftUIText"] = [
                    "height": Double(bare.height),
                    "firstHeight": Double(bare.firstHeight),
                    "settled": bare.settled,
                    "samples": bare.sampleCount,
                ] as [String: Any]
                row["bareTextVsTk2Plain"] = abs(Double(bare.height) - tk2Plain)
                row["productVsBareText"] = abs(Double(product.height) - Double(bare.height))
                if !bare.settled {
                    failures.append("bare text \(fixture.name): not settled")
                }
            } else if fixture.kind == .paragraphs {
                let tk2Plain0 = Double(TextKit2Probe.height(
                    of: typography.plainAttributedString(fixture.text, paragraphSpacing: 0),
                    width: width))
                let tk2Plain12 = Double(TextKit2Probe.height(
                    of: typography.plainAttributedString(fixture.text, paragraphSpacing: 12),
                    width: width))
                row["tk2Plain"] = tk2Plain0
                row["tk2PlainParagraphGap12"] = tk2Plain12
                row["productVsTk2Plain"] = abs(Double(product.height) - tk2Plain12)
            }

            if !product.settled {
                failures.append(
                    "product \(fixture.name): not settled in \(Int(product.elapsedMilliseconds))ms "
                    + "(first \(product.firstHeight), last \(product.height))")
            }
            if !cd.isTextKit2 {
                failures.append("cd \(fixture.name): CDMarkdownTextView is not on TextKit 2")
            }
            rows.append(row)
        }
        report["fixtures"] = rows

        let cdVsTk2Max = rows.compactMap { $0["cdVsTk2"] as? Double }.max() ?? .infinity
        let productPure = rows.first { $0["name"] as? String == "pureParagraph" }
        let productPureDelta = productPure?["productVsTk2Plain"] as? Double ?? .infinity
        let productPureCDDelta = productPure?["productVsCD"] as? Double ?? .infinity

        let checks: [String: Any] = [
            "cdVsTk2Max": cdVsTk2Max,
            "cdVsTk2<=1.0": cdVsTk2Max <= 1.0,
            "pureProductVsTk2": productPureDelta,
            "pureProductVsTk2<=1.0": productPureDelta <= 1.0,
            "pureProductVsCD": productPureCDDelta,
            "pureProductVsCD<=1.0": productPureCDDelta <= 1.0,
        ]
        if cdVsTk2Max > 1.0 {
            failures.append("cd vs tk2 max delta \(cdVsTk2Max) > 1.0")
        }
        if productPureDelta > 1.0 {
            failures.append("pure paragraph product vs tk2 delta \(productPureDelta) > 1.0")
        }
        report["checks"] = checks

        await streaming(typography: typography, width: width)

        report["coverage"] = [
            "measured": "pure Latin/CJK/mixed paragraphs and bare SwiftUI Text (line-height isolation), plain paragraphs (engine parity), long assistant Markdown (shape), table and code (failure probes), per-tick CD parse+measure cost",
            "notMeasured": "images/attachments (network + metadata), selection, links, Dynamic Type, RTL, width changes, streaming glyph reveal, Textual streaming path, real collection cell",
        ]
        finish()
    }

    /// Per-tick cost of the CDMarkdownKit path on a growing reply. The parser
    /// is `@MainActor`, so parse time is main-thread time by construction.
    private func streaming(typography: TextKitSpikeTypography, width: CGFloat) async {
        statusLine = "measuring streaming cost"
        let text = TextKitSpikeFixtures.richLong
        let steps = 20
        var parseTimes: [Double] = []
        var measureTimes: [Double] = []
        var heights: [Double] = []
        for step in 1...steps {
            let prefix = String(text.prefix(text.count * step / steps))
            let (attributed, parseMs) = await CDMarkdownProbe.parse(
                prefix, typography: typography)
            let view = CDMarkdownTextView.makeTextView(frame: .zero)
            view.isScrollEnabled = false
            view.isSelectable = false
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            let started = Date().timeIntervalSinceReferenceDate
            view.attributedText = attributed
            let fitted = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            let measureMs = (Date().timeIntervalSinceReferenceDate - started) * 1000
            parseTimes.append(parseMs)
            measureTimes.append(measureMs)
            heights.append(Double(fitted.height))
        }
        report["streaming"] = [
            "steps": steps,
            "parseMs": Self.stats(parseTimes),
            "measureMs": Self.stats(measureTimes),
            "heights": heights,
            "note": "parse runs on the main actor; measure includes assigning attributedText and sizeThatFits",
        ] as [String: Any]
    }

    private static func stats(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let rank = max(0, min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))
        let p95 = sorted[rank]
        return [
            "median": median,
            "p95": p95,
            "max": sorted.last ?? 0,
            "mean": values.reduce(0, +) / Double(values.count),
        ]
    }

    private func finish() {
        report["failures"] = failures
        report["completed"] = true
        report["passed"] = failures.isEmpty
        writeReport()
        statusLine = failures.isEmpty ? "done" : "done with \(failures.count) failure(s)"
    }

    private func writeReport() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.resultFileName)
        try? data.write(to: url)
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// The spike root. Only reachable through the launch argument; the product
/// root is untouched.
struct TextKitSpikeRootView: View {
    @State private var model = TextKitSpikeModel()

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("TextKit 2 spike").font(.headline)
            Text(model.statusLine).font(.footnote).foregroundStyle(.secondary)
        }
        .task { await model.run() }
    }
}
#endif
