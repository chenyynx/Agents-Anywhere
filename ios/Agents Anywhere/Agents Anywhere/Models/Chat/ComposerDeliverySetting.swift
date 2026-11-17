import Foundation

/// What a message sent while a turn is running does (pp 2026-11-17).
///
/// ONE persisted value drives both the settings row and the send key's
/// long-press menu; there is deliberately no per-send temporary override.
/// `steer` hands the message to the running turn (Claude reads it at its next
/// tool boundary); `queue` keeps it until the turn ends. Runtimes without
/// `session.steer` always fall back to the queue.
enum ComposerDelivery: String, CaseIterable, Identifiable {
    case steer
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer: String(localized: "引导")
        case .queue: String(localized: "排队")
        }
    }
}

enum ComposerDeliverySetting {
    /// The single source of truth shared by the settings row and the
    /// composer's long-press menu.
    static let storageKey = "AA.Composer.MidTurnDelivery"
    static let defaultValue = ComposerDelivery.steer

    /// An unknown value reads as the default instead of surfacing an
    /// unmigrated state to the composer.
    static func resolve(_ raw: String) -> ComposerDelivery {
        ComposerDelivery(rawValue: raw) ?? defaultValue
    }
}
