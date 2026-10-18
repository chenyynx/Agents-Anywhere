import CoreGraphics
import Foundation

/// One row's worth of type settings for the assistant message body.
///
/// A *scheme* is a complete set of these, so switching schemes is one choice
/// instead of eight sliders. `ChatTypeSettings` stores the scheme id plus an
/// optional per-field override; any field the user touches flips the scheme to
/// `.custom` so the two can never disagree.
struct ChatTypeScale: Equatable, Sendable {
    /// Running text.
    var body: CGFloat
    /// Space between line fragments in a paragraph.
    var lineSpacing: CGFloat
    /// Inline code. `nil` means "follow the body via the scheme's ratio".
    var inlineCode: CGFloat?
    /// Fenced code block.
    var codeBlock: CGFloat?
    /// Space between paragraphs.
    var paragraphSpacing: CGFloat
    /// Heading sizes by level (index 0 = h1).
    var headings: [CGFloat]
}

/// The shipped presets.
///
/// - `compact`: what AA has looked like since the refresh. Tight line box,
///   roomier paragraph gap, headings close to the body.
/// - `moonveil`: the local-chat scale from the moonveil app, expressed as the
///   same absolute values its 16.5pt base produces. Wider line box, tighter
///   paragraph gap, headings a full step above the body.
enum ChatTypeScheme: String, CaseIterable, Identifiable, Sendable {
    case compact
    case moonveil
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "AA 紧凑"
        case .moonveil: return "Moonveil 标准"
        case .custom: return "自定义"
        }
    }

    /// `[measured]` AA's current values.
    static let compactScale = ChatTypeScale(
        body: 13,
        lineSpacing: 8,
        inlineCode: nil,
        codeBlock: nil,
        paragraphSpacing: 20,
        headings: [18, 16, 14]
    )

    /// `[measured]` moonveil's local chat at its 16.5pt base: 0.5em leading,
    /// 12pt paragraph gap, headings at 1.5 / 1.3 / 1.15, inline code 0.95 and
    /// code blocks 0.85 of the body.
    static let moonveilScale = ChatTypeScale(
        body: 16.5,
        lineSpacing: 8.25,
        inlineCode: 16.5 * 0.95,
        codeBlock: 16.5 * 0.85,
        paragraphSpacing: 12,
        headings: [16.5 * 1.5, 16.5 * 1.3, 16.5 * 1.15]
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
    /// Re-proportions a scheme onto a different body size. Everything that is
    /// a ratio of the body (leading, code, headings) scales with it; the
    /// paragraph gap is a fixed design constant and stays put, matching how
    /// both schemes were measured.
    func scalingBody(to newBody: CGFloat) -> ChatTypeScale {
        guard body > 0 else { return self }
        let factor = newBody / body
        var copy = self
        copy.body = newBody
        copy.lineSpacing = lineSpacing * factor
        copy.inlineCode = inlineCode.map { $0 * factor }
        copy.codeBlock = codeBlock.map { $0 * factor }
        copy.headings = headings.map { $0 * factor }
        return copy
    }
}
