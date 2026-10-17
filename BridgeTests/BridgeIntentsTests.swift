import Foundation
import Testing
@testable import Bridge

@MainActor
@Suite struct BridgeIntentsTests {
    @Test func paramsMustBeAJSONObject() throws {
        #expect(try RunCapabilityIntent.parse(nil).isEmpty)
        #expect(try RunCapabilityIntent.parse("  ").isEmpty)
        #expect(try RunCapabilityIntent.parse(#"{"name": "notes.txt", "n": 2}"#) == ["name": .string("notes.txt"), "n": .number(2)])
        #expect(throws: IntentFailure.self) { try RunCapabilityIntent.parse("[1, 2]") }
        #expect(throws: IntentFailure.self) { try RunCapabilityIntent.parse("name=notes.txt") }
    }

    @Test func intentRunsShowInTheFeedAndFailuresCarryTheirCode() async throws {
        let result = try await IntentRunner.run("device.info", [:])
        #expect(result["model"] != nil || result["battery_level"] != nil)
        let row = try #require(AppStatus.shared.activity.first { $0.note == "From Shortcuts" })
        #expect(row.capability == "device.info" && row.note == "From Shortcuts" && row.status == .done)

        do {
            _ = try await IntentRunner.run("no.such.thing", [:])
            Issue.record("expected a failure")
        } catch let failure as IntentFailure {
            #expect(failure.code == "unknown_capability")
        }
    }
}
