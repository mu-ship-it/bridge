import Foundation

// HomeKit: 白手套 sees and controls the accessories already set up in Apple's Home app.
// Pairing, rooms and automations stay in the Home app. HomeKit answers only while the app is
// on screen, and iOS asks Mu once for Home access (Status → Request Home).

/// `home.list` {home?} → every home, room, accessory, service and characteristic, with
/// last-known values, plus `summary`: one plain line per accessory ("Living Room / Lamp: power on, brightness 60").
struct HomeListCapability: Capability {
    let name = "home.list"

    func run(_ job: Job) async throws -> JSONValue {
        let home = try Params.string(job.params ?? [:], "home")
        return try await HomeStore.shared.list(home: home)
    }
}

/// `home.get` {accessory, characteristic?, room?, home?} → fresh values read from the accessory:
/// `{accessory, room, reachable, values: {power: true, brightness: 60}}`, or one `value` when
/// `characteristic` is given.
struct HomeGetCapability: Capability {
    let name = "home.get"

    func run(_ job: Job) async throws -> JSONValue {
        let target = try HomeTarget(job.params, needsCharacteristic: false)
        return try await HomeStore.shared.get(target)
    }
}

/// `home.set` {accessory, characteristic, value, room?, home?} → writes one value:
/// `{accessory, characteristic, value}`. Unlocking a lock, opening a garage door or disarming a
/// security system first asks Mu on screen; declining is `cancelled`.
struct HomeSetCapability: Capability {
    let name = "home.set"

    func run(_ job: Job) async throws -> JSONValue {
        let target = try HomeTarget(job.params, needsCharacteristic: true)
        guard let value = job.params?["value"], value != .null else { throw CapabilityError.badParams("'value' is required") }
        return try await HomeStore.shared.set(target, value: value, timeout: try Presenter.timeout(job.params ?? [:]))
    }
}

/// Which accessory (by name or id, optionally narrowed by room / home) and which characteristic.
struct HomeTarget: Sendable, Equatable {
    let accessory: String
    let characteristic: String?
    let room: String?
    let home: String?

    init(_ params: [String: JSONValue]?, needsCharacteristic: Bool) throws {
        let p = params ?? [:]
        guard let accessory = try Params.string(p, "accessory") else {
            throw CapabilityError.badParams("'accessory' (name or id from home.list) is required")
        }
        self.accessory = accessory
        characteristic = try Params.string(p, "characteristic")
        if needsCharacteristic, characteristic == nil {
            throw CapabilityError.badParams("'characteristic' is required, e.g. power, brightness, target_temperature")
        }
        room = try Params.string(p, "room")
        home = try Params.string(p, "home")
    }
}

/// Accessory lookup by name, pure so the ambiguity rules are tested.
enum HomeMatch {
    struct Candidate: Sendable, Equatable {
        let id: String
        let name: String
        let room: String
        let home: String
    }

    /// Exact id, else case-insensitive name (narrowed by room/home). More than one hit is an error naming them.
    static func pick(_ candidates: [Candidate], _ target: HomeTarget) throws -> Int {
        if let i = candidates.firstIndex(where: { $0.id.caseInsensitiveCompare(target.accessory) == .orderedSame }) { return i }
        let same = { (a: String, b: String?) in b == nil || a.compare(b!, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let hits = candidates.indices.filter {
            same(candidates[$0].name, target.accessory) && same(candidates[$0].room, target.room) && same(candidates[$0].home, target.home)
        }
        switch hits.count {
        case 1: return hits[0]
        case 0:
            throw CapabilityError(code: "not_found", message: "No accessory named '\(target.accessory)'"
                + (target.room.map { " in \($0)" } ?? "") + ". Use home.list to see names.")
        default:
            let names = hits.map { "\(candidates[$0].room) / \(candidates[$0].name)" }.joined(separator: ", ")
            throw CapabilityError.badParams("'\(target.accessory)' matches several accessories (\(names)); add 'room' or use the id")
        }
    }
}

/// A value ready to write, checked against the characteristic's metadata.
enum HomeValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    struct Rules: Sendable, Equatable {
        var format: String          // HMCharacteristicMetadataFormat… raw value: bool, int, float, string, uint8…
        var min: Double? = nil
        var max: Double? = nil
        var valid: [Double]? = nil
    }

    var json: JSONValue {
        switch self {
        case .bool(let b): .bool(b)
        case .int(let i): .number(Double(i))
        case .double(let d): .number(d)
        case .string(let s): .string(s)
        }
    }

    var object: NSObject {
        switch self {
        case .bool(let b): NSNumber(value: b)
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .string(let s): s as NSString
        }
    }

    static func coerce(_ value: JSONValue, _ rules: Rules) throws -> HomeValue {
        switch rules.format {
        case "bool":
            if case .string(let s) = value, ["on", "off"].contains(s.lowercased()) { return .bool(s.lowercased() == "on") }
            guard let b = value.boolValue else { throw CapabilityError.badParams("'value' must be true/false (or on/off)") }
            return .bool(b)
        case "string":
            guard case .string(let s) = value else { throw CapabilityError.badParams("'value' must be a string") }
            return .string(s)
        case "int", "uint8", "uint16", "uint32", "uint64", "float":
            var n: Double
            if let b = value.boolValue, case .bool = value { n = b ? 1 : 0 } else {
                guard let d = value.doubleValue, d.isFinite else { throw CapabilityError.badParams("'value' must be a number") }
                n = d
            }
            if rules.format != "float" { n = n.rounded() }
            if let min = rules.min, n < min { throw CapabilityError.badParams("'value' \(fmt(n)) is below the minimum \(fmt(min))") }
            if let max = rules.max, n > max { throw CapabilityError.badParams("'value' \(fmt(n)) is above the maximum \(fmt(max))") }
            if let valid = rules.valid, !valid.isEmpty, !valid.contains(n) {
                throw CapabilityError.badParams("'value' must be one of \(valid.map(fmt).joined(separator: ", "))")
            }
            return rules.format == "float" ? .double(n) : .int(Int(n))
        default:
            throw CapabilityError.badParams("This characteristic (\(rules.format)) cannot be written from 白手套")
        }
    }

    private static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}
