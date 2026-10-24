import Foundation

/// Relative geometry for detecting layout changes and retaining history. It
/// deliberately does not infer arrival or a target offset from native insets.
nonisolated struct TimelineViewport: Equatable {
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
    let visibleBottom: CGFloat
    let offsetY: CGFloat
    let topInset: CGFloat
    /// Screen scale for the official one-physical-pixel tolerance. The
    /// re-arm rule compares `endTarget − offset < 1/displayScale` plus
    /// `anchorPad == 0` (CANONICAL/05-layout-scroll.md §6–7,
    /// `EVIDENCE/part-ag-scroll-params-draft.md` §1.3). Callers that have a
    /// trait collection pass their real scale; the SwiftUI geometry init does
    /// not carry one, so Retina 2× is the fallback (0.5 pt there, 0.333 pt on
    /// a 3× device — both are still the official sub-point dead zone).
    let displayScale: CGFloat

    init(contentHeight: CGFloat = 0, containerHeight: CGFloat = 0,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, offsetY: CGFloat = 0,
         displayScale: CGFloat = 2) {
        self.contentHeight = max(0, contentHeight)
        visibleHeight = max(0, containerHeight - topInset - bottomInset)
        visibleBottom = offsetY + containerHeight - bottomInset
        self.offsetY = offsetY
        self.topInset = topInset
        self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 2
    }
    var isMeasured: Bool { visibleHeight > 0 }

    /// True when the measured scroll rests at its maximum offset — the
    /// content's bottom edge sits at the viewport's. `visibleBottom` reaches
    /// `contentHeight` exactly there by construction (maxOffset =
    /// contentHeight - containerHeight + bottomInset), so the gap is the real
    /// remaining travel; the tolerance is the official **one physical pixel**
    /// (`1/displayScale`, 05 §6–7 / part-ag §1.3), not the old 8 pt. The
    /// marker probes are not consulted: the device probe read "at bottom"
    /// while this gap sat 213 pt short.
    ///
    /// The official re-arm also requires `anchorPad == 0`; this viewport
    /// model has no anchor pad, and the collection controller's re-arm path
    /// carries none, so there is nothing to gate here (see
    /// `TimelineSpringFollow.shouldRearmEnd` for the model that does own
    /// `anchorPad`).
    ///
    /// The one-pixel tolerance is shared by Chat and the Code collection on
    /// purpose: the official re-arm rule belongs to the shared
    /// `SessionCollection` (05 §6–7), so a Code-only tolerance would invent a
    /// second rule. Chat's legacy scroll path was tuned against the old 8 pt
    /// value and has not been probed on device yet; keep one pixel until a
    /// Chat scroll probe shows a regression (review R2 P2-4, decided
    /// 2026-10-24).
    var measuredAtBottom: Bool {
        isMeasured && contentHeight - visibleBottom <= 1 / displayScale
    }
}
