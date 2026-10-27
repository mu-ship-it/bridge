import Foundation

/// `GET /bridge/board/desk` (docs/API.md): what the box composes for the desk display.
/// Every field the box may leave out or null is optional here, so a partial answer still draws.
struct DeskPayload: Decodable, Sendable, Equatable {
    struct Time: Decodable, Sendable, Equatable {
        let now: String
        let tz: String?
        let utcOffsetS: Int?

        enum CodingKeys: String, CodingKey { case now, tz, utcOffsetS = "utc_offset_s" }
    }

    struct Weather: Decodable, Sendable, Equatable {
        let tempC: Double
        let feelsC: Double?
        let humidity: Double?
        let windKmh: Double?
        let code: Int?
        let isDay: Bool?
        let highC: Double?
        let lowC: Double?
        let precipPct: Double?
        let place: String?
        let ageS: Int?
        let stale: Bool?

        enum CodingKeys: String, CodingKey {
            case tempC = "temp_c", feelsC = "feels_c", humidity, windKmh = "wind_kmh", code, isDay = "is_day"
            case highC = "high_c", lowC = "low_c", precipPct = "precip_pct", place, ageS = "age_s", stale
        }
    }

    struct Item: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let kind: String
        let title: String?
        let text: String
        let level: String
        let ts: String
        let speak: Bool
        let source: String?

        enum CodingKeys: String, CodingKey { case id, kind, title, text, level, ts, speak, source }

        init(id: String, kind: String, title: String? = nil, text: String, level: String = "info",
             ts: String, speak: Bool = false, source: String? = nil) {
            (self.id, self.kind, self.title, self.text, self.level, self.ts, self.speak, self.source) =
                (id, kind, title, text, level, ts, speak, source)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            level = try c.decodeIfPresent(String.self, forKey: .level) ?? "info"
            ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
            speak = try c.decodeIfPresent(Bool.self, forKey: .speak) ?? false
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }

        var isWarning: Bool { level == "warn" || level == "critical" }
    }

    struct Presence: Decodable, Sendable, Equatable {
        let present: Bool
        let source: String?
        let idleS: Int?
        let ageS: Int?
        let staleAfterS: Int?

        enum CodingKeys: String, CodingKey {
            case present, source, idleS = "idle_s", ageS = "age_s", staleAfterS = "stale_after_s"
        }
    }

    let time: Time?
    let weather: Weather?
    let attention: [Item]
    let presence: Presence?

    enum CodingKeys: String, CodingKey { case time, weather, attention, presence }

    init(time: Time? = nil, weather: Weather? = nil, attention: [Item] = [], presence: Presence? = nil) {
        (self.time, self.weather, self.attention, self.presence) = (time, weather, attention, presence)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(Time.self, forKey: .time)
        weather = try c.decodeIfPresent(Weather.self, forKey: .weather)
        attention = try c.decodeIfPresent([Item].self, forKey: .attention) ?? []
        presence = try c.decodeIfPresent(Presence.self, forKey: .presence)
    }
}

// MARK: - Tile view-models (pure, so the tests pin what each tile says)

enum DeskText {
    /// Shown wherever a value is unavailable.
    static let missing = "—"
}

/// Tile 2: the room's temperature and humidity, read from HomeKit on this phone.
struct ClimateTile: Equatable, Sendable {
    let temperature: String
    let humidity: String
    let sensor: String?

    init(celsius: Double?, humidity: Double?, sensor: String?) {
        temperature = celsius.map { String(format: "%.1f°", $0) } ?? DeskText.missing
        self.humidity = humidity.map { "\(Int($0.rounded()))%" } ?? DeskText.missing
        self.sensor = sensor
    }
}

/// Tile 3: the box's weather. `summary` is an English key from the catalog, shown localized.
struct WeatherTile: Equatable, Sendable {
    let temperature: String
    let range: String
    let summary: String
    let symbol: String
    let place: String?
    let stale: Bool

    init(_ weather: DeskPayload.Weather?) {
        guard let weather else {
            (temperature, range, summary, symbol, place, stale) =
                (DeskText.missing, DeskText.missing, "No weather", "questionmark.square.dashed", nil, true)
            return
        }
        temperature = "\(Int(weather.tempC.rounded()))°"
        range = if let low = weather.lowC, let high = weather.highC {
            "\(Int(low.rounded()))° / \(Int(high.rounded()))°"
        } else { DeskText.missing }
        let (text, symbol) = Self.describe(code: weather.code, isDay: weather.isDay ?? true)
        (summary, self.symbol, place, stale) = (text, symbol, weather.place, weather.stale ?? false)
    }

    /// WMO weather code (Open-Meteo) → an English catalog key and an SF Symbol.
    static func describe(code: Int?, isDay: Bool) -> (String, String) {
        switch code {
        case 0: ("Clear sky", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2: ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: ("Overcast", "cloud.fill")
        case 45, 48: ("Fog", "cloud.fog.fill")
        case 51, 53, 55, 56, 57: ("Drizzle", "cloud.drizzle.fill")
        case 61, 63, 65, 66, 67, 80, 81, 82: ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77, 85, 86: ("Snow", "cloud.snow.fill")
        case 95, 96, 99: ("Thunderstorm", "cloud.bolt.rain.fill")
        default: ("Weather", "cloud.fill")
        }
    }
}

/// Tile 4: which items are new since the last fetch (they get the haptic and the highlight).
enum AttentionDiff {
    /// Ids in `fresh` not in `seen`. The very first fetch (`seen == nil`) announces nothing:
    /// a relaunch must not buzz for what was already on the board.
    static func newItems(_ fresh: [DeskPayload.Item], seen: Set<String>?) -> [DeskPayload.Item] {
        guard let seen else { return [] }
        return fresh.filter { !seen.contains($0.id) }
    }
}

/// The ack event the phone posts when Mu clears an item (the box drops acked ids from the list).
enum DeskAck {
    static func event(ids: [String], now: Date = Date()) -> DeviceEvent {
        DeviceEvent(type: "attention.ack", ts: ISO.string(now),
                    payload: .object(["ids": .array(ids.map(JSONValue.string))]),
                    note: "Acknowledged on the desk display")
    }
}

/// Which HomeKit accessory is the room sensor. Pure, so the choice is tested.
enum ClimateSensorPick {
    struct Candidate: Sendable, Equatable {
        let name: String
        let room: String
        let hasTemperature: Bool
        let hasHumidity: Bool
    }

    /// `wanted` (the Settings field) matches an accessory name, else a room name, case-insensitively.
    /// Empty `wanted`: the first accessory with both readings, else the first with either.
    static func pick(_ candidates: [Candidate], wanted: String) -> Int? {
        let sensors = candidates.indices.filter { candidates[$0].hasTemperature || candidates[$0].hasHumidity }
        let key = wanted.trimmingCharacters(in: .whitespaces)
        func both(_ i: Int) -> Bool { candidates[i].hasTemperature && candidates[i].hasHumidity }
        func best(_ pool: [Int]) -> Int? { pool.first(where: both) ?? pool.first }
        guard !key.isEmpty else { return best(sensors) }
        let byName = sensors.filter { candidates[$0].name.caseInsensitiveCompare(key) == .orderedSame }
        if let hit = best(byName) { return hit }
        return best(sensors.filter { candidates[$0].room.caseInsensitiveCompare(key) == .orderedSame })
    }
}
