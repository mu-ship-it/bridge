import Foundation

/// HealthKit-free value types so the ingest mapping is unit-testable.
enum HealthMetric: String, CaseIterable, Sendable, Hashable {
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case respiratoryRate = "respiratory_rate"
    case bloodOxygen = "blood_oxygen_saturation"
    case steps = "step_count"

    /// Health Auto Export unit strings.
    var units: String {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: return "count/min"
        case .heartRateVariability: return "ms"
        case .bloodOxygen: return "%"
        case .steps: return "count"
        }
    }

    var isCumulative: Bool { self == .steps }

    /// Accepts HAE names plus short aliases used in `health.query` params.
    init?(param: String) {
        let key = param.lowercased()
        if let m = HealthMetric(rawValue: key) { self = m; return }
        switch key {
        case "hr": self = .heartRate
        case "resting_hr", "rhr": self = .restingHeartRate
        case "hrv": self = .heartRateVariability
        case "rr", "respiratory": self = .respiratoryRate
        case "spo2", "blood_oxygen", "oxygen_saturation": self = .bloodOxygen
        case "steps": self = .steps
        default: return nil
        }
    }
}

struct QuantityPoint: Sendable, Equatable {
    let date: Date
    /// Already in HAE units (e.g. SpO2 as 0–100, not 0–1).
    let qty: Double
    var source: String?
}

enum SleepStage: String, Sendable {
    case inBed = "In Bed"
    case asleep = "Asleep"
    case awake = "Awake"
    case core = "Core"
    case deep = "Deep"
    case rem = "REM"
}

struct SleepSegment: Sendable, Equatable {
    let start: Date
    let end: Date
    let stage: SleepStage
    var source: String?
}

struct WorkoutRecord: Sendable, Equatable {
    let id: String
    let name: String
    let start: Date
    let end: Date
    var activeEnergyKcal: Double?
    var distanceKm: Double?
    var source: String?
}

struct HealthBatch: Sendable {
    var quantities: [HealthMetric: [QuantityPoint]] = [:]
    var sleep: [SleepSegment] = []
    var workouts: [WorkoutRecord] = []

    var isEmpty: Bool { quantities.values.allSatisfy(\.isEmpty) && sleep.isEmpty && workouts.isEmpty }

    var summary: String {
        var parts = HealthMetric.allCases.compactMap { m -> String? in
            guard let n = quantities[m]?.count, n > 0 else { return nil }
            return "\(m.rawValue) \(n)"
        }
        if !sleep.isEmpty { parts.append("sleep \(sleep.count)") }
        if !workouts.isEmpty { parts.append("workouts \(workouts.count)") }
        return parts.isEmpty ? "Nothing new" : parts.joined(separator: ", ")
    }
}

/// Maps samples to the Health Auto Export JSON shape that `POST /hk/ingest` already accepts:
/// `{"data":{"metrics":[{"name","units","data":[{"date","qty"}]}],"workouts":[]}}`
enum HealthIngestMapper {
    static func dateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.string(from: date)
    }

    /// 4 decimal places is plenty and avoids 98.00000000000001 noise.
    static func round(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    static func metricJSON(_ metric: HealthMetric, points: [QuantityPoint], timeZone: TimeZone = .current) -> JSONValue {
        .object([
            "name": .string(metric.rawValue),
            "units": .string(metric.units),
            "data": .array(points.map { p in
                var o: [String: JSONValue] = ["date": .string(dateString(p.date, timeZone: timeZone)), "qty": .number(round(p.qty))]
                if let s = p.source { o["source"] = .string(s) }
                return .object(o)
            }),
        ])
    }

    static func sleepJSON(_ segments: [SleepSegment], timeZone: TimeZone = .current) -> JSONValue {
        .object([
            "name": .string("sleep_analysis"),
            "units": .string("hr"),
            "data": .array(segments.map { s in
                var o: [String: JSONValue] = [
                    "date": .string(dateString(s.start, timeZone: timeZone)),
                    "startDate": .string(dateString(s.start, timeZone: timeZone)),
                    "endDate": .string(dateString(s.end, timeZone: timeZone)),
                    "value": .string(s.stage.rawValue),
                    "qty": .number(round(s.end.timeIntervalSince(s.start) / 3600)),
                ]
                if let src = s.source { o["source"] = .string(src) }
                return .object(o)
            }),
        ])
    }

    static func workoutJSON(_ w: WorkoutRecord, timeZone: TimeZone = .current) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(w.id),
            "name": .string(w.name),
            "start": .string(dateString(w.start, timeZone: timeZone)),
            "end": .string(dateString(w.end, timeZone: timeZone)),
            "duration": .number(round(w.end.timeIntervalSince(w.start))),
        ]
        if let kcal = w.activeEnergyKcal { o["activeEnergyBurned"] = .object(["qty": .number(round(kcal)), "units": .string("kcal")]) }
        if let km = w.distanceKm { o["distance"] = .object(["qty": .number(round(km)), "units": .string("km")]) }
        if let s = w.source { o["source"] = .string(s) }
        return .object(o)
    }

    static func payload(_ batch: HealthBatch, timeZone: TimeZone = .current) -> JSONValue {
        var metrics: [JSONValue] = HealthMetric.allCases.compactMap { m in
            guard let points = batch.quantities[m], !points.isEmpty else { return nil }
            return metricJSON(m, points: points, timeZone: timeZone)
        }
        if !batch.sleep.isEmpty { metrics.append(sleepJSON(batch.sleep, timeZone: timeZone)) }
        return .object(["data": .object([
            "metrics": .array(metrics),
            "workouts": .array(batch.workouts.map { workoutJSON($0, timeZone: timeZone) }),
        ])])
    }

    static func encode(_ batch: HealthBatch, timeZone: TimeZone = .current) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload(batch, timeZone: timeZone))
    }
}
