import Foundation
import HomeKit
import Testing
@testable import Bridge

@Suite struct HomeCapabilityTests {
    let candidates = [
        HomeMatch.Candidate(id: "A1", name: "Lamp", room: "Living Room", home: "Home"),
        HomeMatch.Candidate(id: "B2", name: "Lamp", room: "Bedroom", home: "Home"),
        HomeMatch.Candidate(id: "C3", name: "Front Door", room: "Hallway", home: "Home"),
    ]

    @Test func targetParams() throws {
        #expect(try HomeTarget(["accessory": .string("Lamp")], needsCharacteristic: false).characteristic == nil)
        #expect(throws: CapabilityError.self) { try HomeTarget([:], needsCharacteristic: false) }
        #expect(throws: CapabilityError.self) { try HomeTarget(["accessory": .string("Lamp")], needsCharacteristic: true) }
    }

    @Test func accessoryMatching() throws {
        let t = { (a: String, room: String?) in
            try HomeTarget(["accessory": .string(a), "room": room.map(JSONValue.string) ?? .null], needsCharacteristic: false)
        }
        #expect(try HomeMatch.pick(candidates, t("front door", nil)) == 2)
        #expect(try HomeMatch.pick(candidates, t("lamp", "bedroom")) == 1)
        #expect(try HomeMatch.pick(candidates, t("b2", nil)) == 1)   // id wins
        #expect(throws: CapabilityError.self) { try HomeMatch.pick(candidates, t("Lamp", nil)) }   // ambiguous
        do {
            _ = try HomeMatch.pick(candidates, t("Kettle", nil))
            Issue.record("expected not_found")
        } catch let e as CapabilityError {
            #expect(e.code == "not_found")
        }
    }

    @Test func valueCoercion() throws {
        let bool = HomeValue.Rules(format: "bool")
        #expect(try HomeValue.coerce(.bool(true), bool) == .bool(true))
        #expect(try HomeValue.coerce(.string("off"), bool) == .bool(false))
        #expect(throws: CapabilityError.self) { try HomeValue.coerce(.string("dim"), bool) }

        let brightness = HomeValue.Rules(format: "int", min: 0, max: 100)
        #expect(try HomeValue.coerce(.number(59.6), brightness) == .int(60))
        #expect(throws: CapabilityError.self) { try HomeValue.coerce(.number(140), brightness) }
        #expect(throws: CapabilityError.self) { try HomeValue.coerce(.string("bright"), brightness) }

        let mode = HomeValue.Rules(format: "uint8", min: 0, max: 3, valid: [0, 1, 2])
        #expect(try HomeValue.coerce(.number(2), mode) == .int(2))
        #expect(throws: CapabilityError.self) { try HomeValue.coerce(.number(3), mode) }

        #expect(try HomeValue.coerce(.number(21.5), HomeValue.Rules(format: "float", min: 10, max: 38)) == .double(21.5))
        #expect(throws: CapabilityError.self) { try HomeValue.coerce(.string("x"), HomeValue.Rules(format: "tlv8")) }
    }

    @Test func namesAndSensitiveWrites() {
        #expect(HomeNames.normalize("Power State") == "power_state")
        #expect(HomeNames.normalize("on") == "power")
        #expect(HomeNames.known[HMCharacteristicTypeBrightness] == "brightness")
        #expect(HomeNames.sensitiveAction(HMCharacteristicTypeTargetLockMechanismState, .int(0)) == "unlock")
        #expect(HomeNames.sensitiveAction(HMCharacteristicTypeTargetLockMechanismState, .int(1)) == nil)   // locking is fine
        #expect(HomeNames.sensitiveAction(HMCharacteristicTypeTargetDoorState, .int(0)) == "open")
        #expect(HomeNames.sensitiveAction(HMCharacteristicTypeTargetSecuritySystemState, .int(3)) == "disarm")
        #expect(HomeNames.sensitiveAction(HMCharacteristicTypePowerState, .bool(true)) == nil)
        #expect(HomeNames.text(NSNumber(value: 1), key: "power", format: "bool") == "on")
        #expect(HomeNames.text(NSNumber(value: 21.54), key: "current_temperature", format: "float") == "21.5")
        #expect(HomeNames.json(NSNumber(value: 0), format: "bool") == .bool(false))
    }

    #if targetEnvironment(simulator)
    @Test func homeKitIsCleanlyUnavailableOnTheSimulator() async {
        let dispatcher = JobDispatcher([HomeListCapability(), HomeGetCapability(), HomeSetCapability()])
        let list = await dispatcher.dispatch(Job(id: "1", capability: "home.list"))
        #expect(list.error?.code == "unavailable")
        let set = await dispatcher.dispatch(Job(id: "2", capability: "home.set",
                                                params: ["accessory": .string("Lamp"), "characteristic": .string("power"), "value": .bool(true)]))
        #expect(set.error?.code == "unavailable")
        let bad = await dispatcher.dispatch(Job(id: "3", capability: "home.set", params: ["accessory": .string("Lamp")]))
        #expect(bad.error?.code == "bad_params")
    }
    #endif
}
