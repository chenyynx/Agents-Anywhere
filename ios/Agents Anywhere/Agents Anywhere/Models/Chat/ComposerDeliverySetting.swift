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

    /// The glyph the composer's long-press menu shows in front of each
    /// option: an arrow merging into the running work (steer), a clock for
    /// "after this turn" (queue).
    var menuSymbol: String {
        switch self {
        case .steer: "arrow.turn.down.right"
        case .queue: "clock"
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

    /// The mid-turn action one tap on the send key performs.
    ///
    /// One pure answer for both the send key's enablement and its action, so
    /// "the key is tappable" and "the key does something" cannot disagree:
    /// - `steer` uses the running turn when it can, otherwise the queue;
    /// - `queue` never steers, and is unavailable when the queue is.
    static func midTurnAction(
        _ setting: ComposerDelivery,
        canSteer: Bool,
        canQueue: Bool
    ) -> MidTurnDeliveryAction {
        switch setting {
        case .steer:
            if canSteer { return .steer }
            return canQueue ? .queue : .unavailable
        case .queue:
            return canQueue ? .queue : .unavailable
        }
    }
}

enum MidTurnDeliveryAction: Equatable {
    case steer
    case queue
    case unavailable
}

/// Whether a live turn may take a steering message.
///
/// A turn parked on a permission prompt (`waitingApproval`) or a question
/// (`waiting`) is still the same turn: the runtime holds the message until
/// that step completes and the model reads it inside the turn. Statuses that
/// close the turn window (pending/stopping/blocked/idle) do not steer.
/// What a steering message's optimistic row should say while it waits.
enum SteerPendingStatus: Equatable {
    case sending
    case waiting
    case notDelivered
}

enum SteerPendingStatusResolver {
    /// Official copy follows these states: 发送中 / 正在等待 Claude / 未送达.
    /// `nil` means the record has its own failure UI (`uncertain`/`rejected`).
    static func resolve(
        delivery: V2PendingMessage.Delivery,
        runtimeStatus: V2RuntimeStatus?
    ) -> SteerPendingStatus? {
        switch delivery {
        case .sending:
            return .sending
        case .accepted, .confirmed:
            guard let runtimeStatus else { return .waiting }
            return runtimeStatus.isTurnInFlight ? .waiting : .notDelivered
        case .uncertain, .rejected:
            return nil
        }
    }
}

enum ComposerSteerGate {
    static let steerableStatuses: Set<V2RuntimeStatus> = [
        .running, .waiting, .waitingApproval,
    ]

    static func allows(
        status: V2RuntimeStatus?,
        capabilityAllowed: Bool,
        stopRequested: Bool,
        predictedIdle: Bool,
        isValid: Bool
    ) -> Bool {
        guard isValid, capabilityAllowed, !stopRequested, !predictedIdle else {
            return false
        }
        guard let status else { return false }
        return steerableStatuses.contains(status)
    }
}
