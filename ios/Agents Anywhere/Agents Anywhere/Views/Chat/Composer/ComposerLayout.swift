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
        return CGSize(width: width, height: expanded ? expandedHeight : controls.diameter)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let button = controls.touchTarget
        let inset = expanded ? controls.expandedBottomInset : controls.collapsedInset
        let buttonY = expanded ? bounds.maxY - inset - button : bounds.midY - button / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + inset, y: buttonY), proposal: .init(width: button, height: button))
        // Trailing controls stack leftward from the right edge in declaration
        // order: send first, then the optional command menu and context ring.
        for index in 2..<subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.maxX - inset - button * CGFloat(index - 1), y: buttonY),
                                  proposal: .init(width: button, height: button))
        }
        let textHeight = editorHeight(width: bounds.width, subviews: subviews)
        let textX = expanded ? controls.textInset : inset + button + controls.collapsedTextGap
        subviews[1].place(
            at: CGPoint(x: bounds.minX + textX, y: expanded ? bounds.minY + controls.textInset : bounds.midY - textHeight / 2),
            proposal: .init(width: editorWidth(in: bounds.width, subviews: subviews), height: textHeight)
        )
    }

    private func editorWidth(in width: CGFloat, subviews: Subviews) -> CGFloat {
        // Every trailing control left of send narrows the collapsed editor by
        // one touch target; the expanded editor keeps its own inset row.
        let extra = CGFloat(max(0, subviews.count - 3)) * controls.touchTarget
        return max(1, expanded ? width - controls.textInset * 2
            : width - (controls.touchTarget + controls.collapsedInset + controls.collapsedTextGap) * 2 - extra)
    }

    private func editorHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        min(maximumEditorHeight, subviews[1].sizeThatFits(.init(width: editorWidth(in: width, subviews: subviews), height: nil)).height)
    }
}
