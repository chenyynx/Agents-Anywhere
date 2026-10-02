import Foundation
import CoreGraphics

/// One parsed keyboard notification payload (S2/K5, 2026-10-02). Foundation-only
/// and value-typed so ClientCore tests can pin the parse — including missing
/// fields and the zero-duration boundary — without a simulator.
nonisolated struct TimelineKeyboardEvent: Equatable {
    /// The notification that produced the payload. `willShow`/`willHide` state
    /// their direction outright; `willChangeFrame` carries frames that have to
    /// be compared, which is also how a height-only change (the predictive row,
    /// a keyboard swap) is told apart from an appearance.
    enum Source: Equatable {
        case willShow
        case willHide
        case willChangeFrame
    }

    /// Where the keyboard's top edge is travelling. `unchanged` covers frame
    /// updates that only resize the keyboard.
    enum Direction: Equatable {
        case showing
        case hiding
        case unchanged
    }

    /// The raw `UIKeyboardAnimationCurveUserInfoKey` values. 7 is the private
    /// spring current systems animate the keyboard with; the named cases are
    /// the documented `UIView.AnimationCurve` values.
    enum Curve: Equatable {
        case easeInOut
        case easeIn
        case easeOut
        case linear
        case privateSpring
        case unknown(Int)

        init(rawValue: Int) {
            switch rawValue {
            case 0: self = .easeInOut
            case 1: self = .easeIn
            case 2: self = .easeOut
            case 3: self = .linear
            case 7: self = .privateSpring
            default: self = .unknown(rawValue)
            }
        }
    }

    let source: Source
    let direction: Direction
    let duration: TimeInterval
    let curve: Curve
    let isLocal: Bool

    /// A zero (or absent) duration applies the change without an animation:
    /// there is no transition window worth withholding anything for, and the
    /// settled sample is evaluated right away.
    var isFinal: Bool { duration <= 0 }

    /// The payload keys are the documented raw strings rather than
    /// `UIResponder` constants: ClientCore also builds for macOS, where that
    /// type does not exist.
    private enum Key {
        static let duration = "UIKeyboardAnimationDurationUserInfoKey"
        static let curve = "UIKeyboardAnimationCurveUserInfoKey"
        static let frameBegin = "UIKeyboardFrameBeginUserInfoKey"
        static let frameEnd = "UIKeyboardFrameEndUserInfoKey"
        static let isLocal = "UIKeyboardIsLocalUserInfoKey"
    }

    /// Missing keys never fail the parse: the system always sends duration and
    /// curve in practice, but a payload without them falls back to the
    /// documented defaults (no animation, ease-in-out, local) instead of
    /// dropping the transition.
    init(source: Source, userInfo: [AnyHashable: Any]) {
        self.source = source
        duration = (userInfo[Key.duration] as? NSNumber)?.doubleValue ?? 0
        curve = Curve(rawValue: (userInfo[Key.curve] as? NSNumber)?.intValue ?? 0)
        isLocal = (userInfo[Key.isLocal] as? NSNumber)?.boolValue ?? true
        direction = Self.direction(source: source, userInfo: userInfo)
    }

    private static func direction(source: Source, userInfo: [AnyHashable: Any]) -> Direction {
        switch source {
        case .willShow: return .showing
        case .willHide: return .hiding
        case .willChangeFrame:
            let begin = (userInfo[Key.frameBegin] as? NSValue)?.cgRectValue
            let end = (userInfo[Key.frameEnd] as? NSValue)?.cgRectValue
            guard let begin, let end else { return .unchanged }
            // A zero begin frame is reported by some systems on the first
            // presentation; the non-empty frame then names the direction.
            if begin.isEmpty && !end.isEmpty { return .showing }
            if !begin.isEmpty && end.isEmpty { return .hiding }
            if end.origin.y > begin.origin.y { return .hiding }
            if end.origin.y < begin.origin.y { return .showing }
            return .unchanged
        }
    }
}
