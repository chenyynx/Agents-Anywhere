import SwiftUI

/// The turn's working status as its own transcript row.
///
/// The official Code page draws `••• Computing…` as `CodeThinkingView`, a row
/// of the transcript (CANONICAL/20-working-mark.md §0), not as content inside
/// the last message. Keeping it out of the message row means the status line
/// appearing or disappearing never re-keys a message group and never changes
/// a message row's height.
///
/// The row's height is fixed: the 20 pt flipbook mark, the row's own vertical
/// paddings, and the official 5 pt row margins. The rotating verb does not
/// change the height, so the height key is stable for the row's whole life.
struct CodeWorkingStatusRow: View {
    /// The height the layout reserves before the cell's one self-measure.
    /// Kept next to the view so the two cannot drift.
    static var estimatedHeight: CGFloat {
        CodePageTheme.workingMarkSize
            + 2 * CodePageTheme.segmentVerticalPadding
            + CodePageTheme.rowMarginTop
            + CodePageTheme.rowMarginBottom
    }

    var body: some View {
        CodeThinkingStatusLine()
            .padding(.vertical, CodePageTheme.segmentVerticalPadding)
            .padding(.vertical, CodePageTheme.rowMarginTop)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
