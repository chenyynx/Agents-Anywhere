import Foundation

/// Everything that can change a measured height, and nothing else.
///
/// Width is quantized to 0.5pt so rotation and split-view settling do not
/// thrash the cache with sub-pixel differences. `typographyRevision` is a
/// stable hash of the complete type scale (code ratios/pins included), the
/// inline-code weight, Bold Text, Dynamic Type and layout direction — the set
/// that actually reflows a row. `contentRevision` merges the group signature
/// (row revisions, fold state, inline notice, attachment preview); a streaming
/// row's new revision must produce a new key so it never inherits the previous
/// measured height.
nonisolated struct TimelineHeightKey: Hashable {
    let itemID: String
    let contentRevision: Int
    let width: CGFloat
    let dynamicType: String
    let typographyRevision: Int
    let layoutDirection: Int

    init(itemID: String, contentRevision: Int, width: CGFloat,
         dynamicType: String, typographyRevision: Int, layoutDirection: Int) {
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.width = Self.quantize(width)
        self.dynamicType = dynamicType
        self.typographyRevision = typographyRevision
        self.layoutDirection = layoutDirection
    }

    static func quantize(_ width: CGFloat) -> CGFloat {
        max(0, (width * 2).rounded() / 2)
    }
}

/// The Code page's resolved Markdown roles (Claude iOS 1.261005.20).
///
/// Every value here is already Dynamic-Type resolved by the shared factory
/// (`CodePageTheme.codePageTypography`), so the parser, the renderer and the
/// measurer all read one set of numbers. A `nil` on the snapshot keeps the
/// Chat path byte-for-byte as it was.
///
/// Official evidence: `EVIDENCE/round19/typography-inline.md` §1.2, §2, §7,
/// §8 — H1 24/31.2/550/.title3, H2 20/26/550/.headline, H3+ 17/27.2/550/.body,
/// paragraph-after = size × 1.0, heading-before/after = size × 0.4/0.6,
/// inline code 15/24/.footnote, list indent 24/level.
nonisolated struct CodePageMarkdownRoles: Equatable {
    /// H1, H2, H3+. Levels above 3 use the last entry.
    var headingSizes: [CGFloat]
    /// Parallel to `headingSizes`; the official heading line heights are
    /// 31.2 / 26 / 27.2 unscaled and scale with their own text style.
    var headingLineHeights: [CGFloat]
    /// 0.4 (`headingTopSpacingMultiplier`, default Markdown theme).
    var headingTopSpacingMultiplier: CGFloat
    /// 0.6 (Code page theme override).
    var headingBottomSpacingMultiplier: CGFloat
    /// Space between line fragments of a body run, computed as
    /// `scaledLineHeight − the face's natural line height` (minimum 0).
    var bodyLineSpacing: CGFloat
    /// Inline code (`monospaced` preset, 15 pt, `.footnote`).
    var inlineCodeSize: CGFloat
    /// Inline code's 24 pt line height minus the mono face's natural line
    /// height. The chip itself never changes the paragraph's line height.
    var inlineCodeLineSpacing: CGFloat
    /// The Code theme's `indentSize` (24 pt per list level).
    var listIndent: CGFloat
    /// Item pitch = paragraph-after = body size × 1.0.
    var listSpacing: CGFloat

    func headingSize(for level: Int) -> CGFloat {
        guard !headingSizes.isEmpty else { return 0 }
        let index = min(max(level - 1, 0), headingSizes.count - 1)
        return headingSizes[index]
    }

    func headingLineHeight(for level: Int) -> CGFloat {
        guard !headingLineHeights.isEmpty else { return 0 }
        let index = min(max(level - 1, 0), headingLineHeights.count - 1)
        return headingLineHeights[index]
    }
}

/// The typography inputs that reflow a row. Kept as plain values so the
/// revision can be produced without a UIKit trait environment.
nonisolated struct TimelineTypographySnapshot: Equatable {
    var body: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var headings: [CGFloat]
    var inlineCodeRatio: CGFloat
    var codeBlockRatio: CGFloat
    var codeBlockLineSpacingRatio: CGFloat
    var inlineCodePin: CGFloat?
    var codeBlockPin: CGFloat?
    var inlineCodeBold: Bool
    var boldText: Bool
    var dynamicType: String
    /// 0 for left-to-right, 1 for right-to-left. Markdown block layout caches
    /// are direction-specific.
    var layoutDirection: Int
    /// Resolved official Code-page roles. `nil` = the Chat scheme, unchanged.
    var codeMarkdownRoles: CodePageMarkdownRoles? = nil

    var revision: Int {
        var hasher = TimelineStableHasher()
        hasher.combine(body)
        hasher.combine(lineSpacing)
        hasher.combine(paragraphSpacing)
        for heading in headings { hasher.combine(heading) }
        hasher.combine(inlineCodeRatio)
        hasher.combine(codeBlockRatio)
        hasher.combine(codeBlockLineSpacingRatio)
        hasher.combine(optional: inlineCodePin)
        hasher.combine(optional: codeBlockPin)
        hasher.combine(inlineCodeBold)
        hasher.combine(boldText)
        hasher.combine(dynamicType)
        hasher.combine(layoutDirection)
        if let roles = codeMarkdownRoles {
            hasher.combine(true)
            for size in roles.headingSizes { hasher.combine(size) }
            for height in roles.headingLineHeights { hasher.combine(height) }
            hasher.combine(roles.headingTopSpacingMultiplier)
            hasher.combine(roles.headingBottomSpacingMultiplier)
            hasher.combine(roles.bodyLineSpacing)
            hasher.combine(roles.inlineCodeSize)
            hasher.combine(roles.inlineCodeLineSpacing)
            hasher.combine(roles.listIndent)
            hasher.combine(roles.listSpacing)
        } else {
            hasher.combine(false)
        }
        return hasher.revision
    }
}
