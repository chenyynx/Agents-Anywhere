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

    @Test func optionsExposeTheSettingsCopy() {
        #expect(ComposerDelivery.allCases == [.steer, .queue])
        #expect(ComposerDelivery.steer.title == String(localized: "引导"))
        #expect(ComposerDelivery.queue.title == String(localized: "排队"))
    }
}
