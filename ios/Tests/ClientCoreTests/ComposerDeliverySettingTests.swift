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

    @Test func optionsExposeTheSettingsCopy() {
        #expect(ComposerDelivery.allCases == [.steer, .queue])
        #expect(ComposerDelivery.steer.title == String(localized: "引导"))
        #expect(ComposerDelivery.queue.title == String(localized: "排队"))
    }
}
