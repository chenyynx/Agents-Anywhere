import SwiftUI

/// SwiftUI seam for the collection timeline. C4 owns the product wiring; the
/// C3 gate uses the same representable with synthetic content so the
/// controller is exercised through its real lifecycle.
struct TimelineCollectionView: UIViewControllerRepresentable {
    let content: TimelineCollectionContentProviding
    let measurer: any TimelineHeightMeasuring
    var onPhaseChanged: ((TimelinePhaseMapping.Transition) -> Void)?
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onContentHeightChanged: ((CGFloat) -> Void)?
    /// Integration-gate hook; product wiring leaves it nil.
    var onControllerReady: ((TimelineCollectionController) -> Void)?

    func makeUIViewController(context: Context) -> TimelineCollectionController {
        let controller = TimelineCollectionController()
        controller.configure(measurer: measurer, content: content)
        controller.onPhaseChanged = onPhaseChanged
        controller.onViewportChanged = onViewportChanged
        controller.onContentHeightChanged = onContentHeightChanged
        onControllerReady?(controller)
        return controller
    }

    func updateUIViewController(_ controller: TimelineCollectionController, context: Context) {
        controller.configure(measurer: measurer, content: content)
        controller.onPhaseChanged = onPhaseChanged
        controller.onViewportChanged = onViewportChanged
        controller.onContentHeightChanged = onContentHeightChanged
        controller.reloadFromContent()
    }
}
