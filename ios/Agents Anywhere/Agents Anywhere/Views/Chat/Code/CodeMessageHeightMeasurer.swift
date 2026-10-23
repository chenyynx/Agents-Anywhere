import Foundation
import SwiftUI
import UIKit

/// Measures one Code message row from the views the row actually draws.
///
/// The adapter calls this before a snapshot applies so a settled row never
/// corrects its height under the reader's finger. The code-profile gate calls
/// it for its rendered fixture and compares the result with the hosting
/// view's fitting height, which keeps the arithmetic honest against the real
/// SwiftUI layout.
///
/// Text blocks are laid out as the real `ChatMarkdownView` (Textual), and the
/// user bubble as the real `CodeUserBubble`, inside one reused offscreen
/// `UIHostingController` at the column width. The old implementation measured
/// the assistant body with the TextKit engine and the bubble with
/// `NSAttributedString.boundingRect`; both disagree with what the cell draws
/// (the TextKit path is a separate renderer, the bounding-rect path ignores
/// Textual's line spacing and the bubble's width negotiation), which is what
/// reserved 290 pt for a 354 pt row.
///
/// Tool rows, the working status line and the spacing arithmetic stay in
/// `CodeRowHeightPlan`: those parts are exact constants, and hosting them
/// would cost a layout pass per row for no accuracy.
///
/// `measured: false` is the streaming estimate the list's `prepare()` may ask
/// for. It never hosts a view: it reuses a cached exact component when one is
/// already known and otherwise falls back to the plain-text placeholder. That
/// is what keeps the layout pass free of SwiftUI hosting work.
@MainActor
enum CodeMessageHeightMeasurer {
    static func height(group: ChatTimelineGroup,
                       profile: CodeRuntimeProfile,
                       showsWorkingStatus: Bool,
                       width: CGFloat,
                       typography: TimelineTypographySnapshot,
                       traits: UITraitCollection?,
                       measured: Bool) -> CGFloat {
        let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
        return height(rows: rows, showsWorkingStatus: showsWorkingStatus,
                      width: width, typography: typography, traits: traits,
                      measured: measured)
    }

    static func height(rows: [CodeMessageRow],
                       showsWorkingStatus: Bool,
                       width: CGFloat,
                       typography: TimelineTypographySnapshot,
                       traits: UITraitCollection?,
                       measured: Bool) -> CGFloat {
        let width = TimelineHeightKey.quantize(width)
        let metrics = metrics(traits: traits)
        var trace: [String]?
        let plan = planRows(rows, width: width, typography: typography,
                            traits: traits, metrics: metrics,
                            measured: measured, trace: &trace)
        // `CodeMessageRowView` draws `Color.clear` with no row margins when it
        // has neither a visible block nor the status line.
        if plan.isEmpty && !showsWorkingStatus { return 0 }
        return CodeRowHeightPlan.height(rows: plan,
                                        showsWorkingStatus: showsWorkingStatus,
                                        metrics: metrics)
    }

    /// The blocks `ChatMarkdownView` would parse for `text`, produced
    /// synchronously so the row view can seed its first frame and the
    /// measurer can lay the real view out without a window.
    static func preparedBlocks(for text: String) -> [MarkdownBlockSnapshot]? {
        CodeMessageViewHost.shared.preparedBlocks(for: text)
    }

    /// Component-level numbers for the code-profile gate's report: the user
    /// bubble, every assistant text block, each tool block and the status
    /// line, then the structural contributions. The gate owns the printing;
    /// this only supplies the values, measured exactly like `height(measured:
    /// true)`.
    static func debugBreakdown(group: ChatTimelineGroup,
                               profile: CodeRuntimeProfile,
                               showsWorkingStatus: Bool,
                               width: CGFloat,
                               typography: TimelineTypographySnapshot,
                               traits: UITraitCollection?) -> String {
        let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
        return debugBreakdown(rows: rows, showsWorkingStatus: showsWorkingStatus,
                              width: width, typography: typography, traits: traits)
    }

    static func debugBreakdown(rows: [CodeMessageRow],
                               showsWorkingStatus: Bool,
                               width: CGFloat,
                               typography: TimelineTypographySnapshot,
                               traits: UITraitCollection?) -> String {
        let width = TimelineHeightKey.quantize(width)
        let metrics = metrics(traits: traits)
        var trace: [String]? = []
        let plan = planRows(rows, width: width, typography: typography,
                            traits: traits, metrics: metrics,
                            measured: true, trace: &trace)
        let total = plan.isEmpty && !showsWorkingStatus
            ? 0
            : CodeRowHeightPlan.height(rows: plan,
                                       showsWorkingStatus: showsWorkingStatus,
                                       metrics: metrics)
        var parts = ["total=\(format(total))"]
        parts.append(contentsOf: trace ?? [])
        parts.append("toolRow=\(format(metrics.toolLineHeight + 2 * metrics.toolButtonPadding))")
        parts.append("status=\(format(metrics.statusLineHeight))")
        parts.append("rowSpacing=\(format(metrics.rowSpacing))")
        parts.append("margins=\(format(metrics.rowMargins))")
        return parts.joined(separator: " ")
    }

    // MARK: - Row projection

    /// The rendered rows projected into the pure height plan. User rows join
    /// their text blocks into one bubble; assistant rows keep one measured
    /// block per `.text` block.
    private static func planRows(_ rows: [CodeMessageRow],
                                 width: CGFloat,
                                 typography: TimelineTypographySnapshot,
                                 traits: UITraitCollection?,
                                 metrics: CodeRowHeightPlan.Metrics,
                                 measured: Bool,
                                 trace: inout [String]?) -> [CodeRowHeightPlan.Row] {
        var planRows: [CodeRowHeightPlan.Row] = []
        planRows.reserveCapacity(rows.count)
        for row in rows {
            var blocks: [CodeRowHeightPlan.Block] = []
            if row.role == .user {
                var texts: [String] = []
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
                    case let .text(_, text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(text)
                        }
                    case let .toolCalls(segments):
                        blocks.append(.tools(segments: segments.count))
                        trace?.append(toolTrace(segments: segments.count, metrics: metrics))
                    case .other:
                        blocks.append(.other)
                        trace?.append("other=\(format(metrics.otherLineHeight))")
                    }
                }
                if !texts.isEmpty {
                    let text = texts.joined(separator: "\n\n")
                    let height = bubbleHeight(text, width: width, typography: typography,
                                              traits: traits, measured: measured)
                    blocks.insert(.text(height: height), at: 0)
                    trace?.append("userBubble(\(text.count)ch)=\(format(height))")
                }
            } else {
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
                    case let .text(id, text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        let height = assistantTextHeight(text, width: width,
                                                         typography: typography,
                                                         traits: traits, measured: measured)
                        blocks.append(.text(height: height))
                        // A failed parse falls back to the placeholder; say so
                        // instead of reporting a plausible-looking number.
                        let failed = trace != nil
                            && CodeMessageViewHost.shared.parseFailed(for: text)
                        trace?.append("text[\(id)]=\(format(height))\(failed ? " parse-failed" : "")")
                    case let .toolCalls(segments):
                        blocks.append(.tools(segments: segments.count))
                        trace?.append(toolTrace(segments: segments.count, metrics: metrics))
                    case .other:
                        blocks.append(.other)
                        trace?.append("other=\(format(metrics.otherLineHeight))")
                    }
                }
            }
            if !blocks.isEmpty { planRows.append(CodeRowHeightPlan.Row(blocks: blocks)) }
        }
        return planRows
    }

    private static func toolTrace(segments: Int, metrics: CodeRowHeightPlan.Metrics) -> String {
        let height = CGFloat(max(0, segments))
            * (metrics.toolLineHeight + 2 * metrics.toolButtonPadding)
        return "tools(\(segments)seg)=\(format(height))"
    }

    /// The metrics `CodeMessageRowView` actually lays out with. The tool line
    /// box is a `@ScaledMetric(relativeTo: .footnote)` value, so it must be
    /// scaled with the row's trait collection instead of using 24 pt.
    private static func metrics(traits: UITraitCollection?) -> CodeRowHeightPlan.Metrics {
        let lineHeight = UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: CodePageTheme.toolRowLineHeight, compatibleWith: traits)
        return CodeRowHeightPlan.Metrics(
            blockPadding: 2 * CodePageTheme.segmentVerticalPadding,
            blockSpacing: CodePageTheme.segmentVerticalPadding,
            rowSpacing: CodePageTheme.blockSpacing,
            toolLineHeight: lineHeight,
            toolButtonPadding: CodePageTheme.toolRowButtonPadding,
            otherLineHeight: CodePageTheme.toolRowLineHeight,
            statusLineHeight: CodePageTheme.workingMarkSize
                + 2 * CodePageTheme.segmentVerticalPadding,
            rowMargins: CodePageTheme.rowMarginTop + CodePageTheme.rowMarginBottom)
    }

    // MARK: - Component heights

    private static func assistantTextHeight(_ text: String, width: CGFloat,
                                            typography: TimelineTypographySnapshot,
                                            traits: UITraitCollection?,
                                            measured: Bool) -> CGFloat {
        if measured {
            return CodeMessageViewHost.shared.textHeight(
                text, width: width, typography: typography, traits: traits)
        }
        if let cached = CodeMessageViewHost.shared.cachedTextHeight(
            text, width: width, typography: typography, traits: traits) {
            return cached
        }
        return estimatedAssistantTextHeight(text, width: width, typography: typography)
    }

    private static func bubbleHeight(_ text: String, width: CGFloat,
                                     typography: TimelineTypographySnapshot,
                                     traits: UITraitCollection?,
                                     measured: Bool) -> CGFloat {
        if measured {
            return CodeMessageViewHost.shared.bubbleHeight(
                text, width: width, typography: typography, traits: traits)
        }
        if let cached = CodeMessageViewHost.shared.cachedBubbleHeight(
            text, width: width, typography: typography, traits: traits) {
            return cached
        }
        return estimatedUserBubbleHeight(text, width: width, typography: typography)
    }

    /// The streaming placeholder for a text block. Phase 1 replaces the
    /// estimate with a cell self-measure after the first frame; until then a
    /// live row starts from this plain-text model and settles on the exact
    /// measurement (`measured: true`) before the snapshot applies.
    fileprivate static func estimatedAssistantTextHeight(
        _ text: String, width: CGFloat,
        typography: TimelineTypographySnapshot) -> CGFloat {
        TimelineHeightEstimate.height(
            rows: [TimelineHeightEstimate.TextRow(text: text)], width: width,
            bodySize: typography.body, lineSpacing: typography.lineSpacing,
            paragraphSpacing: typography.paragraphSpacing,
            minimum: 0, cushion: 1)
    }

    /// The streaming placeholder for the user bubble. The exact path hosts
    /// the real `CodeUserBubble`; this only runs while no measurement for the
    /// same text/width/traits is cached, and never inside the exact path.
    fileprivate static func estimatedUserBubbleHeight(
        _ text: String, width: CGFloat,
        typography: TimelineTypographySnapshot) -> CGFloat {
        let available = max(1, width
            - CodePageTheme.userBubbleLeadingGutter
            - 2 * CodePageTheme.userBubbleHorizontalPadding)
        let textHeight = TimelineHeightEstimate.height(
            rows: [TimelineHeightEstimate.TextRow(text: text)], width: available,
            bodySize: typography.body, lineSpacing: typography.lineSpacing,
            paragraphSpacing: typography.paragraphSpacing,
            minimum: 0, cushion: 1)
        return textHeight + 2 * CodePageTheme.userBubbleVerticalPadding
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

/// The offscreen host that lays the real row components out.
///
/// One `UIHostingController` is reused; each measurement replaces its root
/// view and forces a fresh identity (`.id`) so `ChatMarkdownView`'s seeded
/// `@State` takes the new blocks instead of keeping the previous text's.
/// Trait overrides mirror `TimelineHostingHeightMeasurer`: Dynamic Type, RTL,
/// bold text and display scale must match the cell or the height is measured
/// in a different environment than the one it renders in.
@MainActor
private final class CodeMessageViewHost {
    static let shared = CodeMessageViewHost()

    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var textHeights: [Int: CGFloat] = [:]
    private var bubbleHeights: [Int: CGFloat] = [:]
    private var blocksByText: [Int: [MarkdownBlockSnapshot]] = [:]
    private var failedTexts: Set<Int> = []
    private var appliedTraits: TraitSignature?

    private static let textKind = 1
    private static let bubbleKind = 2

    private init() {
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = [.intrinsicContentSize]
    }

    // MARK: - Blocks

    func preparedBlocks(for text: String) -> [MarkdownBlockSnapshot]? {
        let key = Self.textKey(text)
        if let cached = blocksByText[key] { return cached }
        if failedTexts.contains(key) { return nil }
        guard let blocks = try? AssistantMarkdownDocumentParser.parseBlocks(
            text: text, resolvesFileReferences: true) else {
            // A document the shared pipeline cannot parse has no synchronous
            // height either. The measurer falls back to the text estimate and
            // reports the failure in its debug breakdown; retrying the parse
            // on every measurement would only repeat the cost.
            failedTexts.insert(key)
            return nil
        }
        if blocksByText.count > 256 { blocksByText.removeAll(keepingCapacity: true) }
        blocksByText[key] = blocks
        return blocks
    }

    /// True when `text` could not be parsed and the measurer answered with the
    /// placeholder. Exposed for the component-level breakdown.
    func parseFailed(for text: String) -> Bool {
        failedTexts.contains(Self.textKey(text))
    }

    // MARK: - Heights

    func textHeight(_ text: String, width: CGFloat,
                    typography: TimelineTypographySnapshot,
                    traits: UITraitCollection?) -> CGFloat {
        let key = Self.measurementKey(kind: Self.textKind, text: text, width: width,
                                      typography: typography, traits: traits)
        if let cached = textHeights[key] { return cached }
        guard let blocks = preparedBlocks(for: text) else {
            let fallback = CodeMessageHeightMeasurer.estimatedAssistantTextHeight(
                text, width: width, typography: typography)
            Self.cache(fallback, key: key, in: &textHeights)
            return fallback
        }
        applyTraits(traits)
        let view = ChatMarkdownView(text: text, isStreaming: false,
                                    resolvesFileReferences: true,
                                    initialBlocks: blocks)
            .id(key)
        // Every Markdown block is at least one line box. `ChatMarkdownView`
        // draws at `ChatMetrics.bodySize`, and the floor stays above the
        // stack's inter-block gap so the empty body that an unseeded Textual
        // pass reports (gaps only) can never end the loop.
        let lineFloor = max(ChatMetrics.bodySize, 16)
        let minimum = max(1, CGFloat(blocks.count) * lineFloor)
        let height = measure(AnyView(view), width: width, minimum: minimum)
        Self.cache(height, key: key, in: &textHeights)
        return height
    }

    func bubbleHeight(_ text: String, width: CGFloat,
                      typography: TimelineTypographySnapshot,
                      traits: UITraitCollection?) -> CGFloat {
        let key = Self.measurementKey(kind: Self.bubbleKind, text: text, width: width,
                                      typography: typography, traits: traits)
        if let cached = bubbleHeights[key] { return cached }
        applyTraits(traits)
        let view = CodeUserBubble(text: text).id(key)
        // The bubble always carries at least one body line plus its vertical
        // padding; the empty InlineText pass reports only the padding.
        let lineHeight = UIFont.preferredFont(forTextStyle: .body,
                                              compatibleWith: traits).lineHeight
        let minimum = lineHeight + 2 * CodePageTheme.userBubbleVerticalPadding
        let height = measure(AnyView(view), width: width, minimum: minimum)
        Self.cache(height, key: key, in: &bubbleHeights)
        return height
    }

    func cachedTextHeight(_ text: String, width: CGFloat,
                          typography: TimelineTypographySnapshot,
                          traits: UITraitCollection?) -> CGFloat? {
        textHeights[Self.measurementKey(kind: Self.textKind, text: text, width: width,
                                        typography: typography, traits: traits)]
    }

    func cachedBubbleHeight(_ text: String, width: CGFloat,
                            typography: TimelineTypographySnapshot,
                            traits: UITraitCollection?) -> CGFloat? {
        bubbleHeights[Self.measurementKey(kind: Self.bubbleKind, text: text, width: width,
                                          typography: typography, traits: traits)]
    }

    // MARK: - Hosting

    /// Lays the view out and returns its fitting height.
    ///
    /// Textual seeds its parsed content in `onChange(initial: true)`, which
    /// writes `@State` on the first pass and needs a later pass to draw the
    /// text. The loop drives those passes: a state write during layout marks
    /// the hosting view dirty, and the next `layoutIfNeeded` renders it.
    /// `minimum` is the smallest height the real content can have (one line
    /// per Markdown block, or one bubble line); a pass below it is the
    /// transient empty body, so it must not end the loop even when two
    /// consecutive passes agree. The largest observed height wins because
    /// each pass only adds content. There is no async parse on this path —
    /// the Code row hands `ChatMarkdownView` its blocks.
    private func measure(_ view: AnyView, width: CGFloat, minimum: CGFloat) -> CGFloat {
        let proposed = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        hosting.rootView = view
        hosting.view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: 1))
        var height: CGFloat = 0
        var previous: CGFloat = -1
        for _ in 0..<4 {
            hosting.view.layoutIfNeeded()
            let pass = max(0, hosting.sizeThatFits(in: proposed).height)
            if pass >= minimum, abs(pass - previous) <= 0.5 { return pass }
            previous = pass
            height = max(height, pass)
        }
        return height
    }

    private func applyTraits(_ traits: UITraitCollection?) {
        let signature = TraitSignature(traits)
        guard signature != appliedTraits else { return }
        appliedTraits = signature
        hosting.traitOverrides.preferredContentSizeCategory = signature.contentSize
        hosting.traitOverrides.layoutDirection = signature.layoutDirection
        hosting.traitOverrides.legibilityWeight = signature.legibility
        hosting.traitOverrides.userInterfaceStyle = signature.style
        hosting.traitOverrides.displayScale = signature.displayScale
    }

    private struct TraitSignature: Equatable {
        let contentSize: UIContentSizeCategory
        let displayScale: CGFloat
        let layoutDirection: UITraitEnvironmentLayoutDirection
        let legibility: UILegibilityWeight
        let style: UIUserInterfaceStyle

        init(_ traits: UITraitCollection?) {
            let current = UITraitCollection.current
            contentSize = traits?.preferredContentSizeCategory
                ?? current.preferredContentSizeCategory
            let scale = traits?.displayScale ?? current.displayScale
            displayScale = scale > 0 ? scale : 2
            layoutDirection = traits?.layoutDirection ?? current.layoutDirection
            legibility = traits?.legibilityWeight ?? current.legibilityWeight
            style = traits?.userInterfaceStyle ?? current.userInterfaceStyle
        }
    }

    // MARK: - Keys

    private static func textKey(_ text: String) -> Int {
        var hasher = TimelineStableHasher()
        hasher.combine(text)
        return hasher.revision
    }

    private static func measurementKey(kind: Int, text: String, width: CGFloat,
                                       typography: TimelineTypographySnapshot,
                                       traits: UITraitCollection?) -> Int {
        var hasher = TimelineStableHasher()
        hasher.combine(kind)
        hasher.combine(text)
        hasher.combine(TimelineHeightKey.quantize(width))
        hasher.combine(typography.revision)
        hasher.combine(optional: traits?.preferredContentSizeCategory.rawValue)
        hasher.combine(optional: traits.map { $0.displayScale })
        hasher.combine(traits?.layoutDirection.rawValue ?? -1)
        hasher.combine(traits?.legibilityWeight.rawValue ?? -1)
        hasher.combine(traits?.userInterfaceStyle.rawValue ?? -1)
        return hasher.revision
    }

    // Static so the inout store does not overlap an access to `self`.
    private static func cache(_ height: CGFloat, key: Int, in store: inout [Int: CGFloat]) {
        if store.count > 512 { store.removeAll(keepingCapacity: true) }
        store[key] = height
    }
}
