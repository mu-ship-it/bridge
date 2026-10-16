import CoreLocation
import Foundation

/// One-shot CLLocation fix. params: `timeout` seconds (default 20, max 60).
struct LocationNowCapability: Capability {
    let name = "location.now"

    func run(_ job: Job) async throws -> JSONValue {
        let seconds = min(max(job.params?["timeout"]?.doubleValue ?? 20, 1), 60)
        let fix = try await LocationService.shared.oneShot(timeout: .seconds(seconds))
        return await MainActor.run {
            var o: [String: JSONValue] = [
                "lat": .number(fix.coordinate.latitude),
                "lon": .number(fix.coordinate.longitude),
                "horizontal_accuracy_m": .number(fix.horizontalAccuracy),
                "timestamp": .string(ISO.string(fix.timestamp)),
            ]
            if fix.verticalAccuracy >= 0 { o["altitude_m"] = .number(fix.altitude) }
            if fix.speed >= 0 { o["speed_mps"] = .number(fix.speed) }
            if fix.course >= 0 { o["course_deg"] = .number(fix.course) }
            return .object(o)
        }
    }
}
