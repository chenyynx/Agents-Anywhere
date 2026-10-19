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
        return hasher.revision
    }
}
