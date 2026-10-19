import SwiftUI
import UIKit

/// Offscreen `UIHostingController` measurement.
///
/// Textual exposes `StructuredText` as a SwiftUI view with no public
/// measurement API (`sizeThatFits` stays inside its blocks), so the only
/// measurement guaranteed to agree with the rendered cell is the same view
/// hierarchy hosted offscreen at the same width. The controller reuses one
/// hosting controller; the factory swaps the root view per item.
///
/// The factory must produce exactly the cell's content view (same environment
/// values, same parsed Markdown input). Any divergence shows up as the C3
/// measurement-consistency failure, which is the intended alarm.
@MainActor
final class TimelineHostingHeightMeasurer: TimelineHeightMeasuring {
    /// Builds the real row view for an item. Called on the main thread.
    private let makeView: (String) -> AnyView
    private let hosting: UIHostingController<AnyView>
    let traitOverrides: UITraitCollection?

    private(set) var measurementCount = 0

    init(traitOverrides: UITraitCollection? = nil,
         makeView: @escaping (String) -> AnyView) {
        self.traitOverrides = traitOverrides
        self.makeView = makeView
        hosting = UIHostingController(rootView: AnyView(EmptyView()))
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = [.intrinsicContentSize]
        if let traitOverrides {
            hosting.traitOverrides.preferredContentSizeCategory = traitOverrides.preferredContentSizeCategory
            hosting.traitOverrides.layoutDirection = traitOverrides.layoutDirection
            hosting.traitOverrides.legibilityWeight = traitOverrides.legibilityWeight
            hosting.traitOverrides.userInterfaceStyle = traitOverrides.userInterfaceStyle
            hosting.traitOverrides.displayScale = traitOverrides.displayScale
        }
    }

    /// The controller's traits are the authoritative Dynamic Type / RTL /
    /// display scale once the representable is in the hierarchy. The adapter
    /// creates this measurer before that point, so refresh them before the
    /// first measurement instead of keeping the offscreen defaults.
    func updateTraitOverrides(from traits: UITraitCollection) {
        hosting.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
        hosting.traitOverrides.layoutDirection = traits.layoutDirection
        hosting.traitOverrides.legibilityWeight = traits.legibilityWeight
        hosting.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
        hosting.traitOverrides.displayScale = traits.displayScale
    }

    func measure(itemID: String, width: CGFloat) -> CGFloat? {
        guard width > 0 else { return nil }
        hosting.rootView = makeView(itemID)
        let proposed = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        hosting.view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: 1))
        hosting.view.layoutIfNeeded()
        let size = hosting.sizeThatFits(in: proposed)
        measurementCount += 1
        guard size.height.isFinite, size.height > 0 else { return nil }
        return ceil(size.height)
    }
}
