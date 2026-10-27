import Foundation
import HomeKit
import UIKit

/// The one HMHomeManager. HomeKit objects are not Sendable, so they never leave the main actor:
/// every method here turns them into JSON before returning.
@MainActor
final class HomeStore: NSObject, HMHomeManagerDelegate {
    static let shared = HomeStore()

    /// Set by the Status screen's "Ask" button for Home. Creating an HMHomeManager is what makes
    /// iOS ask, so a job never creates one before Mu has asked for it on screen.
    private static let requestedKey = "home.requested"
    private var manager: HMHomeManager?
    private var loaded = false

    // MARK: Permission

    func requestAuthorization() {
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        _ = loadedManager()
    }

    var state: String {
        #if targetEnvironment(simulator)
        return "Not on the simulator"
        #else
        guard UserDefaults.standard.bool(forKey: Self.requestedKey) else { return PermissionState.notAsked }
        let status = loadedManager().authorizationStatus
        if status.contains(.authorized) { return PermissionState.granted }
        if status.contains(.restricted) { return PermissionState.restricted }
        return status.contains(.determined) ? PermissionState.denied : PermissionState.notAsked
        #endif
    }

    private func loadedManager() -> HMHomeManager {
        if let manager { return manager }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        return m
    }

    /// The homes, once HomeKit has loaded them, or the reason they are not available.
    private func homes() async throws -> [HMHome] {
        #if targetEnvironment(simulator)
        throw CapabilityError.unavailable("HomeKit is not available on the simulator")
        #else
        guard UserDefaults.standard.bool(forKey: Self.requestedKey) else { throw CapabilityError.permissionMissing("Home") }
        try Presenter.requireForeground()
        let m = loadedManager()
        for _ in 0..<40 where !loaded { try await Task.sleep(for: .milliseconds(250)) }
        let status = m.authorizationStatus
        guard status.contains(.authorized) else {
            if status.contains(.restricted) { throw CapabilityError.unavailable("Home access is restricted on this phone") }
            throw CapabilityError.permissionDenied("Home")
        }
        guard loaded else { throw CapabilityError(code: "timeout", message: "HomeKit did not load the homes within 10 s") }
        return m.homes
        #endif
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.loaded = true }
    }

    // MARK: Capabilities

    func list(home name: String?) async throws -> JSONValue {
        var homes = try await homes()
        if let name {
            homes = homes.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard !homes.isEmpty else { throw CapabilityError(code: "not_found", message: "No home named '\(name)'") }
        }
        var summary: [JSONValue] = []
        let out: [JSONValue] = homes.map { home in
            let rooms = ([home.roomForEntireHome()] + home.rooms).compactMap { room -> JSONValue? in
                let accessories = home.accessories.filter { $0.room == room }
                guard !accessories.isEmpty else { return nil }
                return .object(["name": .string(room.name), "accessories": .array(accessories.map { accessory in
                    summary.append(.string(Self.summaryLine(accessory, home: homes.count > 1 ? home.name : nil)))
                    return Self.describe(accessory)
                })])
            }
            return .object([
                "name": .string(home.name),
                "id": .string(home.uniqueIdentifier.uuidString),
                "primary": .bool(home.isPrimary),
                "rooms": .array(rooms),
            ])
        }
        return .object(["homes": .array(out), "summary": .array(summary)])
    }

    func get(_ target: HomeTarget) async throws -> JSONValue {
        let accessory = try await find(target)
        guard accessory.isReachable else { throw Self.unreachable(accessory) }
        if let key = target.characteristic {
            let c = try Self.characteristic(key, in: accessory)
            try await Self.read(c)
            return .object([
                "accessory": .string(accessory.name),
                "room": .string(accessory.room?.name ?? ""),
                "characteristic": .string(HomeNames.key(c)),
                "value": HomeNames.json(c.value, format: c.metadata?.format),
            ])
        }
        var values: [String: JSONValue] = [:]
        for c in Self.visible(accessory) where c.properties.contains(HMCharacteristicPropertyReadable) {
            try? await Self.read(c)
            values[HomeNames.key(c)] = HomeNames.json(c.value, format: c.metadata?.format)
        }
        return .object([
            "accessory": .string(accessory.name),
            "room": .string(accessory.room?.name ?? ""),
            "reachable": .bool(accessory.isReachable),
            "values": .object(values),
        ])
    }

    func set(_ target: HomeTarget, value: JSONValue, timeout: Int) async throws -> JSONValue {
        let accessory = try await find(target)
        guard accessory.isReachable else { throw Self.unreachable(accessory) }
        let c = try Self.characteristic(target.characteristic ?? "", in: accessory)
        guard c.properties.contains(HMCharacteristicPropertyWritable) else {
            throw CapabilityError.badParams("'\(HomeNames.key(c))' on \(accessory.name) is read-only")
        }
        let rules = HomeValue.Rules(format: c.metadata?.format ?? "", min: c.metadata?.minimumValue?.doubleValue,
                                    max: c.metadata?.maximumValue?.doubleValue,
                                    valid: c.metadata?.validValues?.map(\.doubleValue))
        let v = try HomeValue.coerce(value, rules)
        if let action = HomeNames.sensitiveAction(c.characteristicType, v) {
            try await Self.confirm("\(action) “\(accessory.name)”" + (accessory.room.map { " (\($0.name))" } ?? ""), timeout: timeout)
        }
        try await Self.write(c, v.object)
        return .object([
            "accessory": .string(accessory.name),
            "characteristic": .string(HomeNames.key(c)),
            "value": v.json,
        ])
    }

    // MARK: Desk display

    /// The room sensor's temperature (°C) and humidity (%) for the desk display: the accessory
    /// `wanted` names (accessory or room, see ClimateSensorPick), read fresh. Nil values when the
    /// sensor lacks one or the read fails; throws only when HomeKit or a sensor is unavailable.
    func climate(wanted: String) async throws -> (celsius: Double?, humidity: Double?, sensor: String) {
        let all = try await homes().flatMap(\.accessories)
        func reading(_ a: HMAccessory, _ type: String) -> HMCharacteristic? {
            a.services.lazy.flatMap(\.characteristics).first { $0.characteristicType == type }
        }
        let candidates = all.map { a in
            ClimateSensorPick.Candidate(name: a.name, room: a.room?.name ?? "",
                                        hasTemperature: reading(a, HMCharacteristicTypeCurrentTemperature) != nil,
                                        hasHumidity: reading(a, HMCharacteristicTypeCurrentRelativeHumidity) != nil)
        }
        guard let index = ClimateSensorPick.pick(candidates, wanted: wanted) else {
            throw CapabilityError(code: "not_found", message: "No accessory with a temperature or humidity sensor")
        }
        let accessory = all[index]
        guard accessory.isReachable else { throw Self.unreachable(accessory) }
        func value(_ type: String) async -> Double? {
            guard let c = reading(accessory, type) else { return nil }
            try? await Self.read(c)
            return (c.value as? NSNumber)?.doubleValue
        }
        return (await value(HMCharacteristicTypeCurrentTemperature),
                await value(HMCharacteristicTypeCurrentRelativeHumidity), accessory.name)
    }

    // MARK: Helpers

    private func find(_ target: HomeTarget) async throws -> HMAccessory {
        let all = try await homes().flatMap { home in home.accessories.map { (home, $0) } }
        let candidates = all.map { home, a in
            HomeMatch.Candidate(id: a.uniqueIdentifier.uuidString, name: a.name, room: a.room?.name ?? "", home: home.name)
        }
        return all[try HomeMatch.pick(candidates, target)].1
    }

    private static func unreachable(_ a: HMAccessory) -> CapabilityError {
        CapabilityError.unavailable("\(a.name) is not reachable right now (off, out of range, or no home hub)")
    }

    /// The characteristics worth showing: user-facing services, no name/identify plumbing.
    private static func visible(_ accessory: HMAccessory) -> [HMCharacteristic] {
        accessory.services.filter { $0.serviceType != HMServiceTypeAccessoryInformation }.flatMap { service in
            service.characteristics.filter { c in
                ![HMCharacteristicTypeName, HMCharacteristicTypeIdentify].contains(c.characteristicType)
                    && (c.properties.contains(HMCharacteristicPropertyReadable) || c.properties.contains(HMCharacteristicPropertyWritable))
            }
        }
    }

    private static func characteristic(_ key: String, in accessory: HMAccessory) throws -> HMCharacteristic {
        let wanted = HomeNames.normalize(key)
        let all = visible(accessory)
        if let c = all.first(where: { HomeNames.key($0) == wanted || $0.characteristicType.caseInsensitiveCompare(key) == .orderedSame }) {
            return c
        }
        let names = Array(Set(all.map(HomeNames.key))).sorted().joined(separator: ", ")
        throw CapabilityError(code: "not_found", message: "\(accessory.name) has no '\(key)'. It has: \(names)")
    }

    private static func describe(_ accessory: HMAccessory) -> JSONValue {
        let services: [JSONValue] = accessory.services.filter { $0.serviceType != HMServiceTypeAccessoryInformation }.map { service in
            let characteristics: [JSONValue] = service.characteristics.filter { c in visible(accessory).contains(c) }.map { c in
                var o: [String: JSONValue] = [
                    "name": .string(HomeNames.key(c)),
                    "description": .string(c.localizedDescription),
                    "value": HomeNames.json(c.value, format: c.metadata?.format),
                    "writable": .bool(c.properties.contains(HMCharacteristicPropertyWritable)),
                    "format": c.metadata?.format.map(JSONValue.string) ?? .null,
                ]
                if let unit = c.metadata?.units { o["unit"] = .string(HomeNames.unit(unit)) }
                if let min = c.metadata?.minimumValue { o["min"] = .number(min.doubleValue) }
                if let max = c.metadata?.maximumValue { o["max"] = .number(max.doubleValue) }
                if let valid = c.metadata?.validValues, !valid.isEmpty { o["valid"] = .array(valid.map { .number($0.doubleValue) }) }
                return .object(o)
            }
            return .object(["name": .string(service.name), "type": .string(service.localizedDescription),
                            "characteristics": .array(characteristics)])
        }
        return .object([
            "name": .string(accessory.name),
            "id": .string(accessory.uniqueIdentifier.uuidString),
            "room": .string(accessory.room?.name ?? ""),
            "reachable": .bool(accessory.isReachable),
            "category": .string(accessory.category.localizedDescription),
            "services": .array(services),
        ])
    }

    private static func summaryLine(_ accessory: HMAccessory, home: String?) -> String {
        let values = visible(accessory).filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
            .compactMap { c -> String? in
                guard let v = HomeNames.text(c.value, key: HomeNames.key(c), format: c.metadata?.format) else { return nil }
                return "\(HomeNames.key(c)) \(v)"
            }
        let place = [home, accessory.room?.name, accessory.name].compactMap { $0 }.joined(separator: " / ")
        let state = accessory.isReachable ? values.joined(separator: ", ") : "not reachable"
        return state.isEmpty ? place : "\(place): \(state)"
    }

    private static func read(_ c: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            c.readValue { error in
                once.resume(error.map { .failure(CapabilityError(code: "failed", message: "Read failed: \($0.localizedDescription)")) } ?? .success(()))
            }
            Task { try? await Task.sleep(for: .seconds(8)); once.resume(.failure(CapabilityError(code: "timeout", message: "The accessory did not answer within 8 s"))) }
        }
    }

    private static func write(_ c: HMCharacteristic, _ value: NSObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            c.writeValue(value) { error in
                once.resume(error.map { .failure(CapabilityError(code: "failed", message: "Write failed: \($0.localizedDescription)")) } ?? .success(()))
            }
            Task { try? await Task.sleep(for: .seconds(10)); once.resume(.failure(CapabilityError(code: "timeout", message: "The accessory did not answer within 10 s"))) }
        }
    }

    /// Asks Mu on screen before an action that opens the home up. "Don't Allow" is `cancelled`.
    private static func confirm(_ action: String, timeout: Int) async throws {
        let allowed: Bool = try await Presenter.present(timeout: timeout) { session in
            let alert = UIAlertController(title: "白手套", message: "Your agent asks to \(action).", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { _ in session.succeed(false) })
            alert.addAction(UIAlertAction(title: "Allow", style: .destructive) { _ in session.succeed(true) })
            return alert
        }
        guard allowed else { throw CapabilityError.cancelled }
    }
}

/// Short, stable names for HomeKit characteristics, units and values. Pure.
enum HomeNames {
    static let known: [String: String] = [
        HMCharacteristicTypePowerState: "power",
        HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeHue: "hue",
        HMCharacteristicTypeSaturation: "saturation",
        HMCharacteristicTypeColorTemperature: "color_temperature",
        HMCharacteristicTypeCurrentTemperature: "current_temperature",
        HMCharacteristicTypeTargetTemperature: "target_temperature",
        HMCharacteristicTypeCurrentHeatingCooling: "current_heating_cooling",
        HMCharacteristicTypeTargetHeatingCooling: "target_heating_cooling",
        HMCharacteristicTypeTemperatureUnits: "temperature_units",
        HMCharacteristicTypeCurrentRelativeHumidity: "humidity",
        HMCharacteristicTypeTargetRelativeHumidity: "target_humidity",
        HMCharacteristicTypeCurrentLockMechanismState: "lock_current",
        HMCharacteristicTypeTargetLockMechanismState: "lock_target",
        HMCharacteristicTypeCurrentDoorState: "door_current",
        HMCharacteristicTypeTargetDoorState: "door_target",
        HMCharacteristicTypeObstructionDetected: "obstruction",
        HMCharacteristicTypeActive: "active",
        HMCharacteristicTypeInUse: "in_use",
        HMCharacteristicTypeOutletInUse: "outlet_in_use",
        HMCharacteristicTypeRotationSpeed: "rotation_speed",
        HMCharacteristicTypeCurrentPosition: "current_position",
        HMCharacteristicTypeTargetPosition: "target_position",
        HMCharacteristicTypeMotionDetected: "motion",
        HMCharacteristicTypeContactState: "contact",
        HMCharacteristicTypeOccupancyDetected: "occupancy",
        HMCharacteristicTypeSmokeDetected: "smoke",
        HMCharacteristicTypeCarbonDioxideLevel: "co2",
        HMCharacteristicTypeAirQuality: "air_quality",
        HMCharacteristicTypeCurrentLightLevel: "light_level",
        HMCharacteristicTypeBatteryLevel: "battery_level",
        HMCharacteristicTypeStatusLowBattery: "low_battery",
        HMCharacteristicTypeCurrentSecuritySystemState: "security_current",
        HMCharacteristicTypeTargetSecuritySystemState: "security_target",
        HMCharacteristicTypeMute: "mute",
        HMCharacteristicTypeVolume: "volume",
    ]

    /// "Power State" → "power_state"; also accepts "on" for power.
    static func normalize(_ s: String) -> String {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return t == "on" ? "power" : t
    }

    @MainActor
    static func key(_ c: HMCharacteristic) -> String {
        known[c.characteristicType] ?? normalize(c.localizedDescription)
    }

    /// Writes that open the home up and so ask Mu first: unlock, open a garage door, disarm.
    static func sensitiveAction(_ type: String, _ value: HomeValue) -> String? {
        switch (type, value) {
        case (HMCharacteristicTypeTargetLockMechanismState, .int(0)): "unlock"
        case (HMCharacteristicTypeTargetDoorState, .int(0)): "open"
        case (HMCharacteristicTypeTargetSecuritySystemState, .int(3)): "disarm"
        default: nil
        }
    }

    static func json(_ value: Any?, format: String?) -> JSONValue {
        switch value {
        case let n as NSNumber where format == "bool": .bool(n.boolValue)
        case let n as NSNumber: .number((n.doubleValue * 1000).rounded() / 1000)
        case let s as String: .string(s)
        case let d as Data: .string(d.base64EncodedString())
        default: .null
        }
    }

    static func text(_ value: Any?, key: String, format: String?) -> String? {
        switch value {
        case let n as NSNumber where format == "bool":
            ["power", "active", "mute"].contains(key) ? (n.boolValue ? "on" : "off") : (n.boolValue ? "yes" : "no")
        case let n as NSNumber: n.doubleValue == n.doubleValue.rounded() ? String(n.intValue) : String(format: "%.1f", n.doubleValue)
        case let s as String: s
        default: nil
        }
    }

    static func unit(_ raw: String) -> String {
        switch raw {
        case HMCharacteristicMetadataUnitsCelsius: "celsius"
        case HMCharacteristicMetadataUnitsFahrenheit: "fahrenheit"
        case HMCharacteristicMetadataUnitsPercentage: "percent"
        case HMCharacteristicMetadataUnitsArcDegree: "degrees"
        case HMCharacteristicMetadataUnitsSeconds: "seconds"
        case HMCharacteristicMetadataUnitsLux: "lux"
        case HMCharacteristicMetadataUnitsPartsPerMillion: "ppm"
        case HMCharacteristicMetadataUnitsMicrogramsPerCubicMeter: "µg/m³"
        default: raw
        }
    }
}
