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

    /// While true the flipbook runs; false starts the official 0.4 s exit
    /// (`EVIDENCE/round19/streaming.md:188`) while the status text stays on
    /// screen. The caller must keep this row mounted for those 0.4 s and then
    /// remove it: the mark cannot remove itself, and the official exit group
    /// is 0.4 s long (`CANONICAL/20-working-mark.md:53`). Give the row the
    /// same view identity across that transition; a re-created view starts
    /// already exited (invisible) and never plays the 0.4 s exit.
    let isRunning: Bool

    /// The official live-turn pose (`SessionDisplay.liveTurnMark`); the
    /// adapter recomputes it as the turn's last event changes. Stored as
    /// `markBody` because `body` is SwiftUI's view requirement.
    let markBody: WorkingMarkBody

    /// The official working-status phase (connecting / compacting / rotating
    /// verbs); the adapter recomputes it from the turn's events.
    let phase: CodeWorkingStatusPhase

    init(isRunning: Bool = true,
         markBody: WorkingMarkBody = .think,
         phase: CodeWorkingStatusPhase = .working(startedAt: Date())) {
        self.isRunning = isRunning
        self.markBody = markBody
        self.phase = phase
    }

    var body: some View {
        CodeThinkingStatusLine(isRunning: isRunning, markBody: markBody, phase: phase)
            .padding(.vertical, CodePageTheme.segmentVerticalPadding)
            .padding(.vertical, CodePageTheme.rowMarginTop)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
