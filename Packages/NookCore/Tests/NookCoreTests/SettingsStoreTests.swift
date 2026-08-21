import Foundation
import Testing
@testable import NookCore

@Suite struct SettingsStoreTests {
    @Test func invalidEnumFieldFallsBackWithoutResettingOthers() throws {
        var store = SettingsStore()
        store.onboardingCompleted = true
        store.rehideDelay = 3.5
        let data = try JSONEncoder().encode(store)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Simulate a downgrade: a raw value this build's enum doesn't know.
        json["displayTemplate"] = "someFutureBehavior"
        let poisoned = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SettingsStore.self, from: poisoned)
        #expect(decoded.displayTemplate == SettingsStore().displayTemplate)
        #expect(decoded.onboardingCompleted == true)
        #expect(decoded.rehideDelay == 3.5)
    }
}
