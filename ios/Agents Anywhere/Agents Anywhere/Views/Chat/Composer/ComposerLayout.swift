import SwiftUI

/// Repositions the composer's subviews, preserving the editor and its IME state.
struct ComposerLayout: Layout {
    let expanded: Bool
    let maximumEditorHeight: CGFloat
    let controls: ChatControlMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 350)
        let textHeight = editorHeight(width: width, subviews: subviews)
        let expandedHeight = controls.textInset + textHeight + controls.textToActions
            + controls.touchTarget + controls.expandedBottomInset
        return CGSize(width: width, height: expanded ? expandedHeight : controls.collapsedHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let button = controls.touchTarget
        let leadingInset = expanded ? controls.expandedContentInset : controls.collapsedLeadingInset
        let trailingInset = expanded ? controls.expandedContentInset : controls.collapsedTrailingInset
        let buttonY = expanded
            ? bounds.maxY - controls.expandedBottomInset - button
            : bounds.midY - button / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + leadingInset, y: buttonY),
                          proposal: .init(width: button, height: button))
        // Trailing controls stack leftward from the right edge in declaration
        // order: send first, then the optional context ring and command menu.
        for index in 2..<subviews.count {
            // Controls past the second trailing slot (index >= 4 — today the
            // command menu when it follows the ring) are 18 pt neighbours whose
            // uniform 44 pt slot leaves a 26 pt visible gap, while send's 36 pt
            // circle leaves its neighbour 17 pt. Shift them right by the drawn
            // difference (sendDiameter - contextRingDiameter)/2 = (36 - 18)/2
            // = 9 pt so every neighbouring pair reads evenly spaced. A control
            // placed directly after send (index 3) is left alone: its slot
            // already yields the same gap.
            let nudge = index >= 4 ? controls.sendDiameter / 2 - ChatControlMetrics.contextRingDiameter / 2 : 0
            subviews[index].place(
                at: CGPoint(x: bounds.maxX - trailingInset - button * CGFloat(index - 1) + nudge, y: buttonY),
                proposal: .init(width: button, height: button))
        }
        let textHeight = editorHeight(width: bounds.width, subviews: subviews)
        let textX = expanded ? controls.textInset : leadingInset + button + controls.collapsedTextGap
        subviews[1].place(
            at: CGPoint(x: bounds.minX + textX, y: expanded ? bounds.minY + controls.textInset : bounds.midY - textHeight / 2),
            proposal: .init(width: editorWidth(in: bounds.width, subviews: subviews), height: textHeight)
        )
    }

    private func editorWidth(in width: CGFloat, subviews: Subviews) -> CGFloat {
        // Each trailing control (send, plus any ring/command slots) narrows the
        // collapsed editor by one touch target; the expanded editor keeps its
        // own text inset row.
        let leading = expanded ? controls.expandedContentInset : controls.collapsedLeadingInset
        let trailing = expanded ? controls.expandedContentInset : controls.collapsedTrailingInset
        let trailingControls = CGFloat(max(0, subviews.count - 2)) * controls.touchTarget
        return max(1, expanded ? width - controls.textInset * 2
            : width - (leading + controls.touchTarget + controls.collapsedTextGap)
                - trailing - trailingControls)
    }

    private func editorHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        min(maximumEditorHeight, subviews[1].sizeThatFits(.init(width: editorWidth(in: width, subviews: subviews), height: nil)).height)
    }
}
