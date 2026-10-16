import Foundation

/// Parsed `health.query` params. Pure, so it is unit-testable.
/// metric: HAE name or alias, or `sleep` / `workouts`; from/to: ISO-8601 (default last 24h);
/// interval: `raw` (default), `minute`, `hour`, `day`, `week`, `month`, or `<n>m|h|d`; limit: max raw samples (default 5000).
struct HealthQueryParams: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        case quantity(HealthMetric)
        case sleep
        case workouts
    }

    let target: Target
    let from: Date
    let to: Date
    let interval: DateComponents?
    let limit: Int

    init(_ params: [String: JSONValue]?, now: Date = Date()) throws {
        let p = params ?? [:]
        guard let metric = p["metric"]?.stringValue else { throw CapabilityError.badParams("'metric' is required") }
        switch metric.lowercased() {
        case "sleep", "sleep_analysis", "sleep_stages": target = .sleep
        case "workouts", "workout": target = .workouts
        default:
            guard let m = HealthMetric(param: metric) else {
                throw CapabilityError.badParams("Unknown metric '\(metric)'. Use one of: \(HealthMetric.allCases.map(\.rawValue).joined(separator: ", ")), sleep, workouts")
            }
            target = .quantity(m)
        }

        to = try p["to"]?.stringValue.map(Self.parseDate) ?? now
        from = try p["from"]?.stringValue.map(Self.parseDate) ?? to.addingTimeInterval(-24 * 3600)
        guard from < to else { throw CapabilityError.badParams("'from' must be before 'to'") }

        interval = try Self.parseInterval(p["interval"]?.stringValue ?? "raw")
        limit = max(1, min(Int(p["limit"]?.doubleValue ?? 5000), 20_000))
    }

    private static func parseDate(_ raw: String) throws -> Date {
        guard let d = ISO.date(raw) else { throw CapabilityError.badParams("Bad date '\(raw)' (use ISO-8601)") }
        return d
    }

    static func parseInterval(_ raw: String) throws -> DateComponents? {
        switch raw.lowercased() {
        case "raw", "", "none": return nil
        case "minute": return DateComponents(minute: 1)
        case "hour": return DateComponents(hour: 1)
        case "day": return DateComponents(day: 1)
        case "week": return DateComponents(day: 7)
        case "month": return DateComponents(month: 1)
        default:
            let s = raw.lowercased()
            guard let unit = s.last, let n = Int(s.dropLast()), n > 0 else {
                throw CapabilityError.badParams("Bad interval '\(raw)'")
            }
            switch unit {
            case "m": return DateComponents(minute: n)
            case "h": return DateComponents(hour: n)
            case "d": return DateComponents(day: n)
            default: throw CapabilityError.badParams("Bad interval '\(raw)'")
            }
        }
    }
}

struct HealthQueryCapability: Capability {
    let name = "health.query"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try HealthQueryParams(job.params)
        let health = HealthService.shared
        guard health.isAvailable else { throw CapabilityError(code: "unavailable", message: "HealthKit not available") }

        var out: [String: JSONValue] = [
            "from": .string(ISO.string(q.from)),
            "to": .string(ISO.string(q.to)),
            "interval": .string(job.params?["interval"]?.stringValue ?? "raw"),
        ]
        let series: JSONValue
        switch q.target {
        case .quantity(let metric):
            if let interval = q.interval {
                let buckets = try await health.statistics(metric, from: q.from, to: q.to, interval: interval)
                series = .object(["name": .string(metric.rawValue), "units": .string(metric.units), "data": .array(buckets)])
            } else {
                series = HealthIngestMapper.metricJSON(metric, points: try await health.quantitySamples(metric, from: q.from, to: q.to, limit: q.limit))
            }
        case .sleep:
            series = HealthIngestMapper.sleepJSON(try await health.sleep(from: q.from, to: q.to, limit: q.limit))
        case .workouts:
            let workouts = try await health.workouts(from: q.from, to: q.to, limit: q.limit)
            series = .object(["name": .string("workouts"), "data": .array(workouts.map { HealthIngestMapper.workoutJSON($0) })])
        }
        out["metric"] = series
        out["count"] = .number(Double(series["data"]?.arrayValue?.count ?? 0))
        return .object(out)
    }
}
