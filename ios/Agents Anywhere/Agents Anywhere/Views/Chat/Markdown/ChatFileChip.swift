import SwiftUI
import Textual
import UIKit

// MARK: - Overview
//
// Two Textual attachments that render a *recognized* file reference (the
// backtick / bare-path entries of §3.3b) as visual, clickable objects:
//
// - `ChatFileChipAttachment` — an inline capsule embedded in a text run. It
//   replaces a code run (entry ①) or a bare-path token (entry ②). The body is
//   `PathChipLabel`, wrapped in a `Button` that opens `FileLink.url(path:)`
//   (`aafile://open?path=`) through the environment `openURL`. `SessionChatView`
//   turns that scheme into the workspace-open path (`openReference`).
// - `ChatFileCardAttachment` — a full-width card shown when a whole paragraph is
//   exactly one path (a path alone on its own line).
//
// Both mirror `ChatGitBadgeAttachment`: a `nonisolated` value type whose
// `sizeThatFits(_:in:)` reserves the footprint (Textual draws a placeholder of
// that size and overlays the real view on top of it) and whose
// `baselineOffset(in:)` seats the object on the text line. Visual values are the
// delivered design values in `FilePathStyle.swift`
// (`ChipMetrics` / `ChipPalette` / `CardMetrics`) — never "improve" them here.

// MARK: - 1. Inline chip (entry ① backtick / entry ② bare token)

nonisolated struct ChatFileChipAttachment: Attachment {
    /// The path handed to the open link. It keeps any trailing `:line:col` so
    /// the preview still focuses the source location (`SessionFileReference`
    /// splits the location back out in `openReference`).
    let path: String
    /// The inline-code / bare text shown inside the capsule.
    let display: String
    /// The visual type; `.folder` for a directory-shaped path.
    let kind: FileKind

    var description: String { display }
    var selectionStyle: AttachmentSelectionStyle { .text }

    /// - Parameter isDirectory: pass `true`/`false` only when the caller knows;
    ///   `nil` lets `FileKind` infer a folder from a trailing slash or a dotless
    ///   name (the design's default).
    init(path: String, display: String, isDirectory: Bool? = nil) {
        self.path = path
        self.display = display
        self.kind = FileKind(path: path, isDirectory: isDirectory)
    }

    @MainActor var body: some View {
        ChatFileChip(path: path, display: display, kind: kind)
            .textual.textSelectionExcluded()
    }

    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat {
        // The placeholder is bottom-aligned to the text baseline; lift the
        // capsule so its vertical center lands near the body's cap-height middle.
        let metrics = ChipSizing.metrics(for: display, kind: kind, environment: environment)
        return metrics.bodySize * 0.34 - metrics.height / 2
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        let metrics = ChipSizing.metrics(for: display, kind: kind, environment: environment)
        // Cap the width like `ChatGitBadge` so a pathological huge path does not
        // reserve an unbounded first-pass footprint; the capsule's own
        // `.lineLimit(1)` / `.truncationMode(.middle)` elides the middle once a
        // finite column width arrives.
        let width = min(metrics.width, proposal.width ?? 320)
        return CGSize(width: max(0, width), height: metrics.height)
    }
}

/// The chip's intrinsic metrics, matching exactly what `ChatFileChip` renders.
///
/// The live view draws `PathChipLabel` at `@ScaledMetric(relativeTo: .callout)`
/// body size 16; here the same number is resolved from the environment's
/// `dynamicTypeSize` with `UIFontMetrics`, so the reserved footprint tracks the
/// drawn capsule 1:1. Measurements mirror the design's `ChipImage` recipe
/// (text width by the chip font, icon block, insets).
private nonisolated enum ChipSizing {
    struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let bodySize: CGFloat
    }

    static func metrics(for text: String, kind: FileKind?, environment: TextEnvironmentValues) -> Metrics {
        let bodySize = self.bodySize(for: environment.dynamicTypeSize)
        let palette = kind == nil ? ChipPalette.neutral : ChipPalette.link
        let font = ChipFont.make(size: bodySize * ChipMetrics.fontRatio)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let iconBlock = kind == nil ? 0 : ChipMetrics.iconSize + ChipMetrics.iconGap
        let contentHeight = max(font.lineHeight, kind == nil ? 0 : ChipMetrics.iconSize)
        // The 1px border is drawn inside the frame (`strokeBorder`), so it adds
        // no footprint here — unlike the design's bitmap, which padded for it.
        let width = ceil(palette.insets.left + iconBlock + textWidth + palette.insets.right)
        let height = ceil(palette.insets.top + contentHeight + palette.insets.bottom)
        return Metrics(width: width, height: height, bodySize: bodySize)
    }

    /// The body point size `ChatFileChip`'s `@ScaledMetric(relativeTo: .callout)`
    /// would resolve for this Dynamic Type size.
    private static func bodySize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category(for: dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .callout).scaledValue(for: 16, compatibleWith: traits)
    }

    private static func category(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

private struct ChatFileChip: View {
    let path: String
    let display: String
    let kind: FileKind
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .callout) private var bodySize: CGFloat = 16

    var body: some View {
        Button {
            if let url = FileLink.url(path: path) { openURL(url) }
        } label: {
            PathChipLabel(text: display, kind: kind, bodySize: bodySize)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display)
        .accessibilityIdentifier("markdown.fileChip")
    }
}

// MARK: - 2. Full-width card (a path alone on its own line)

nonisolated struct ChatFileCardAttachment: Attachment {
    let path: String

    var description: String { path }

    @MainActor var body: some View {
        ChatFileCard(path: path)
            .textual.textSelectionExcluded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        // The card scales with Dynamic Type (one `@ScaledMetric(relativeTo:.body)`
        // step over every fixed design value); reserve the same scaled height so
        // Textual's placeholder matches the drawn card. `@ScaledMetric` == 1 at
        // the default size, so `.large` resolves to the design height 62.
        let traits = UITraitCollection(preferredContentSizeCategory: category(for: environment.dynamicTypeSize))
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits)
        return CGSize(width: proposal.width ?? 320, height: CardMetrics.height * scale)
    }

    private func category(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

private struct ChatFileCard: View {
    let path: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        FileCardView(path: path) {
            if let url = FileLink.url(path: path) { openURL(url) }
        }
    }
}
