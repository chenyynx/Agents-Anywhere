import SwiftUI
import UIKit

/// SwiftUI seam for the collection timeline. C4 owns the product wiring; the
/// C3 gate uses the same representable with synthetic content so the
/// controller is exercised through its real lifecycle.
struct TimelineCollectionView: UIViewControllerRepresentable {
    let content: TimelineCollectionContentProviding
    let measurer: any TimelineHeightMeasuring
    /// Nil keeps the provider's own scale (the C3 gate). The product wrapper
    /// passes the view's environment so a Dynamic Type or RTL change produces
    /// new height keys.
    var typography: TimelineTypographySnapshot? = nil
    /// The page's SwiftUI safe area, read inside the composer `safeAreaBar`
    /// (bar + home indicator + keyboard). The controller turns it into the
    /// official content inset; the collection view is a full-screen bleed.
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var onPhaseChanged: ((TimelinePhaseMapping.Transition) -> Void)?
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onContentHeightChanged: ((CGFloat) -> Void)?
    /// Integration-gate hook; product wiring leaves it nil.
    var onControllerReady: ((TimelineCollectionController) -> Void)?

    func makeUIViewController(context: Context) -> TimelineCollectionController {
        let controller = TimelineCollectionController()
        if let typography { content.applyTypography(typography) }
        controller.safeAreaInsets = UIEdgeInsets(top: safeAreaInsets.top,
                                                 left: safeAreaInsets.leading,
                                                 bottom: safeAreaInsets.bottom,
                                                 right: safeAreaInsets.trailing)
        controller.configure(measurer: measurer, content: content)
        controller.onPhaseChanged = onPhaseChanged
        controller.onViewportChanged = onViewportChanged
        controller.onContentHeightChanged = onContentHeightChanged
        onControllerReady?(controller)
        return controller
    }

    func updateUIViewController(_ controller: TimelineCollectionController, context: Context) {
        content.prepareForUpdate()
        if let typography { content.applyTypography(typography) }
        controller.safeAreaInsets = UIEdgeInsets(top: safeAreaInsets.top,
                                                 left: safeAreaInsets.leading,
                                                 bottom: safeAreaInsets.bottom,
                                                 right: safeAreaInsets.trailing)
        controller.configure(measurer: measurer, content: content)
        controller.onPhaseChanged = onPhaseChanged
        controller.onViewportChanged = onViewportChanged
        controller.onContentHeightChanged = onContentHeightChanged
        controller.reloadFromContent()
    }
}
