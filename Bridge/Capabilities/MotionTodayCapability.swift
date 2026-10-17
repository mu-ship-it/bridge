@preconcurrency import CoreMotion
import Foundation

/// `motion.today` → `{from, to, steps, distance_m?, floors_up?, floors_down?}` from CMPedometer since local midnight. No params.
struct MotionTodayCapability: Capability {
    let name = "motion.today"

    func run(_ job: Job) async throws -> JSONValue {
        guard CMPedometer.isStepCountingAvailable() else { throw CapabilityError.unavailable("Step counting is not available on this device") }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: throw CapabilityError.permissionDenied("Motion")
        default: break // notDetermined: the query itself shows the prompt (foreground only)
        }
        let now = Date()
        let from = Self.startOfDay(now)
        let o = try await Self.query(from: from, to: now)
        var out = o
        out["from"] = .string(ISO.string(from))
        out["to"] = .string(ISO.string(now))
        return .object(out)
    }

    /// Local midnight for `now` in `calendar`'s time zone.
    static func startOfDay(_ now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    static func query(from: Date, to: Date) async throws -> [String: JSONValue] {
        let pedometer = CMPedometer()
        return try await withCheckedThrowingContinuation { cont in
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                if let error {
                    let code = (error as NSError).code
                    if code == Int(CMErrorMotionActivityNotAuthorized.rawValue) {
                        return cont.resume(throwing: CapabilityError.permissionDenied("Motion"))
                    }
                    return cont.resume(throwing: CapabilityError.unavailable("Pedometer: \(error.localizedDescription)"))
                }
                guard let data else { return cont.resume(throwing: CapabilityError.unavailable("No pedometer data")) }
                var o: [String: JSONValue] = ["steps": .number(data.numberOfSteps.doubleValue)]
                if let d = data.distance { o["distance_m"] = .number(HealthIngestMapper.round(d.doubleValue)) }
                if let f = data.floorsAscended { o["floors_up"] = .number(f.doubleValue) }
                if let f = data.floorsDescended { o["floors_down"] = .number(f.doubleValue) }
                cont.resume(returning: o)
            }
        }
    }

    /// Triggers the Motion & Fitness prompt by running one query.
    static func requestAuthorization() async {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let now = Date()
        _ = try? await query(from: startOfDay(now), to: now)
    }
}
