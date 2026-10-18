import CoreGraphics
import Foundation

/// One row's worth of type settings for the assistant message body.
///
/// A *scheme* is a complete set of these, so switching schemes is one choice
/// instead of eight sliders. `ChatTypeSettings` stores the scheme id plus an
/// optional per-field override; any field the user touches flips the scheme to
/// `.custom` so the two can never disagree.
///
/// Code sizes come in two forms on purpose. The *ratio* is the scheme's design
/// proportion against the body; the *pin* is an absolute size the reader chose.
/// A pinned element stops tracking the body — which is what AA has always done
/// for fenced code (a fixed 12.3pt that never moved when the body changed) and
/// is the whole point of offering the setting.
struct ChatTypeScale: Equatable, Sendable {
    /// Running text.
    var body: CGFloat
    /// Space between line fragments in a paragraph.
    var lineSpacing: CGFloat
    /// Space between paragraphs.
    var paragraphSpacing: CGFloat
    /// Heading sizes by level (index 0 = h1).
    var headings: [CGFloat]
    /// Inline code as a multiple of the body.
    var inlineCodeRatio: CGFloat
    /// Fenced code block as a multiple of the body.
    var codeBlockRatio: CGFloat
    /// Leading inside a fenced code block, as a share of the code size.
    /// A ratio rather than a point value: a reader who pins code at 17pt must
    /// get proportionally more air, not the same 2pt squeezed under bigger
    /// glyphs.
    var codeBlockLineSpacingRatio: CGFloat
    /// Absolute overrides. When set, the element keeps this exact size no
    /// matter what the body is.
    var inlineCodePin: CGFloat?
    var codeBlockPin: CGFloat?

    var inlineCodeSize: CGFloat { inlineCodePin ?? body * inlineCodeRatio }
    var codeBlockSize: CGFloat { codeBlockPin ?? body * codeBlockRatio }
}

/// The shipped presets.
///
/// - `compact`: what AA has looked like since the refresh. Tight line box,
///   roomier paragraph gap, headings close to the body, fenced code pinned at
///   its measured 12.3pt.
/// - `moonveil`: the local-chat scale from the moonveil app, expressed as the
///   same absolute values its 16.5pt base produces. Wider line box, tighter
///   paragraph gap, headings a full step above the body, both code sizes
///   proportional to it.
enum ChatTypeScheme: String, CaseIterable, Identifiable, Sendable {
    case compact
    case moonveil
    case custom

    var id: String { rawValue }

    /// Named for the shape, not for where it came from: a reader picking a
    /// preset is choosing how tight the page looks, and "AA" or "Moonveil"
    /// only tells them which codebase it was measured in.
    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .moonveil: return "标准"
        case .custom: return "自定义"
        }
    }

    /// `[measured]` AA's current values. Inline code was always a ratio of the
    /// body (14.8pt against the 14pt reference); fenced code was a constant,
    /// so it is pinned at its measured size rather than re-derived — deriving
    /// it from the 13pt body would silently shrink it below what ships.
    static let compactScale = ChatTypeScale(
        body: 13,
        lineSpacing: 8,
        paragraphSpacing: 20,
        headings: [18, 16, 14],
        inlineCodeRatio: 14.8 / 14,
        // What turning「跟随正文」on produces at the shipped body size: the
        // same 12.3pt the pin holds, so the toggle never moves the text.
        codeBlockRatio: 12.3 / 13,
        // `[measured]` 43px baseline pitch minus the 12.3pt glyphs = 2.03pt.
        codeBlockLineSpacingRatio: (14.33 - 12.3) / 12.3,
        inlineCodePin: nil,
        codeBlockPin: 12.3
    )

    /// `[measured]` moonveil's local chat at its 16.5pt base: 0.5em leading,
    /// 12pt paragraph gap, headings at 1.5 / 1.3 / 1.15, inline code 0.95 and
    /// code blocks 0.85 of the body, with a flat 4pt of leading in code.
    static let moonveilScale = ChatTypeScale(
        body: 16.5,
        lineSpacing: 8.25,
        paragraphSpacing: 12,
        headings: [16.5 * 1.5, 16.5 * 1.3, 16.5 * 1.15],
        inlineCodeRatio: 0.95,
        codeBlockRatio: 0.85,
        codeBlockLineSpacingRatio: 4 / (16.5 * 0.85),
        inlineCodePin: nil,
        codeBlockPin: nil
    )

    func scale(bodyOverride: CGFloat?) -> ChatTypeScale? {
        switch self {
        case .compact:
            guard let bodyOverride, bodyOverride != Self.compactScale.body else { return Self.compactScale }
            return Self.compactScale.scalingBody(to: bodyOverride)
        case .moonveil:
            guard let bodyOverride, bodyOverride != Self.moonveilScale.body else { return Self.moonveilScale }
            return Self.moonveilScale.scalingBody(to: bodyOverride)
        case .custom:
            return nil
        }
    }
}

extension ChatTypeScale {
    /// Re-proportions a scheme onto a different body size.
    ///
    /// Only what is *measured as a multiple* of the body moves: leading and
    /// headings. The paragraph gap is a fixed design constant in both schemes,
    /// and a pinned code size means the reader (or the scheme) asked for an
    /// absolute size — dragging the body must not drag it along.
    func scalingBody(to newBody: CGFloat) -> ChatTypeScale {
        guard body > 0 else { return self }
        let factor = newBody / body
        var copy = self
        copy.body = newBody
        copy.lineSpacing = lineSpacing * factor
        copy.headings = headings.map { $0 * factor }
        return copy
    }
}
