import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct ComposerDeliverySettingTests {
    @Test func defaultsToSteerForMissingOrUnknownValues() {
        #expect(ComposerDeliverySetting.defaultValue == .steer)
        #expect(ComposerDeliverySetting.resolve("") == .steer)
        #expect(ComposerDeliverySetting.resolve("garbage") == .steer)
    }

    @Test func persistedValuesRoundTrip() {
        #expect(ComposerDeliverySetting.resolve("steer") == .steer)
        #expect(ComposerDeliverySetting.resolve("queue") == .queue)
    }

    @Test func midTurnActionMatrix() {
        // Steer setting uses the running turn; falls back to the queue.
        #expect(ComposerDeliverySetting.midTurnAction(.steer, canSteer: true, canQueue: true) == .steer)
        #expect(ComposerDeliverySetting.midTurnAction(.steer, canSteer: true, canQueue: false) == .steer)
        #expect(ComposerDeliverySetting.midTurnAction(.steer, canSteer: false, canQueue: true) == .queue)
        #expect(ComposerDeliverySetting.midTurnAction(.steer, canSteer: false, canQueue: false) == .unavailable)
        // The queue setting never steers, even when steering is possible.
        #expect(ComposerDeliverySetting.midTurnAction(.queue, canSteer: true, canQueue: true) == .queue)
        #expect(ComposerDeliverySetting.midTurnAction(.queue, canSteer: true, canQueue: false) == .unavailable)
        #expect(ComposerDeliverySetting.midTurnAction(.queue, canSteer: false, canQueue: true) == .queue)
        #expect(ComposerDeliverySetting.midTurnAction(.queue, canSteer: false, canQueue: false) == .unavailable)
    }

    @Test func steerGateAcceptsLiveTurnsIncludingAwaits() {
        // A permission prompt / question is the same turn, not a closed one.
        for status in [V2RuntimeStatus.running, .waiting, .waitingApproval] {
            #expect(ComposerSteerGate.allows(
                status: status, capabilityAllowed: true,
                stopRequested: false, predictedIdle: false, isValid: true))
        }
        // Closed or closing windows must fall back to the queue.
        for status in [
            V2RuntimeStatus.pending, .stopping, .blocked, .idle, .error,
            .disconnected, .unknown,
        ] {
            #expect(!ComposerSteerGate.allows(
                status: status, capabilityAllowed: true,
                stopRequested: false, predictedIdle: false, isValid: true))
        }
    }

    @Test func steerGateHonoursItsGuards() {
        #expect(!ComposerSteerGate.allows(
            status: .running, capabilityAllowed: false,
            stopRequested: false, predictedIdle: false, isValid: true))
        #expect(!ComposerSteerGate.allows(
            status: .running, capabilityAllowed: true,
            stopRequested: true, predictedIdle: false, isValid: true))
        #expect(!ComposerSteerGate.allows(
            status: .running, capabilityAllowed: true,
            stopRequested: false, predictedIdle: true, isValid: true))
        #expect(!ComposerSteerGate.allows(
            status: .running, capabilityAllowed: true,
            stopRequested: false, predictedIdle: false, isValid: false))
        #expect(!ComposerSteerGate.allows(
            status: nil, capabilityAllowed: true,
            stopRequested: false, predictedIdle: false, isValid: true))
    }

    @Test func steerPendingStatusFollowsDeliveryAndTurnState() {
        #expect(SteerPendingStatusResolver.resolve(
            delivery: .sending, runtimeStatus: .running) == .sending)
        // Anything still inside the turn window is "waiting", including the
        // closing states: a stop may still end with the runtime reading it.
        for status in [
            V2RuntimeStatus.running, .waiting, .waitingApproval, .pending,
            .stopping, .blocked,
        ] {
            #expect(SteerPendingStatusResolver.resolve(
                delivery: .accepted, runtimeStatus: status) == .waiting)
        }
        // A turn that ended without an echo is not a failure: the steer stays
        // queued for the next turn until the runtime's `steerOutcomes` says
        // otherwise (probe 2026-11-21). Claiming 未送达 here caused a resend
        // that duplicated the message.
        for status in [
            V2RuntimeStatus.idle, .error, .disconnected, .unknown,
        ] {
            #expect(SteerPendingStatusResolver.resolve(
                delivery: .accepted, runtimeStatus: status) == .heldForNextTurn)
        }
        #expect(SteerPendingStatusResolver.resolve(
            delivery: .accepted, runtimeStatus: nil) == .waiting)
        let failure = V2ClientFailure(kind: .unavailable, message: "x")
        #expect(SteerPendingStatusResolver.resolve(
            delivery: .uncertain(failure), runtimeStatus: .running) == nil)
        #expect(SteerPendingStatusResolver.resolve(
            delivery: .rejected(failure), runtimeStatus: .running) == nil)
    }

    @Test func optionsExposeTheSettingsCopy() {
        #expect(ComposerDelivery.allCases == [.steer, .queue])
        #expect(ComposerDelivery.steer.title == String(localized: "引导"))
        #expect(ComposerDelivery.queue.title == String(localized: "排队"))
    }
}
