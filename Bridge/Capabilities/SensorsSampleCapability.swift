import CoreMotion
import Foundation

/// Parsed `sensors.sample` params: `seconds` (1–10, default 2), `hz` (1–50, default 10).
struct SensorsSampleParams: Sendable, Equatable {
    let seconds: Int
    let hz: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        seconds = try Params.int(p, "seconds", in: 1...10) ?? 2
        hz = try Params.int(p, "hz", in: 1...50) ?? 10
    }
}

/// `sensors.sample` → raw sensor readings over a short window. Each sensor is
/// `{available, samples: [[t, …]]}` with `t` in seconds from the start:
/// - `accelerometer` `[t, x, y, z]` in g · `gyro` `[t, x, y, z]` in rad/s · `magnetometer` `[t, x, y, z]` in µT
/// - `barometer` `[t, pressure_kpa, relative_altitude_m]` — about once a second, needs Motion & Fitness access.
struct SensorsSampleCapability: Capability {
    let name = "sensors.sample"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try SensorsSampleParams(job.params)
        let motion = CMMotionManager()
        let barometer = CMAltimeter.isRelativeAltitudeAvailable() && CMAltimeter.authorizationStatus() == .authorized
        guard motion.isAccelerometerAvailable || motion.isGyroAvailable || motion.isMagnetometerAvailable
              || CMAltimeter.isRelativeAltitudeAvailable() else {
            throw CapabilityError.unavailable("No motion sensors on this device (simulator?)")
        }

        let log = SampleLog()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let interval = 1.0 / Double(q.hz)
        let start = ProcessInfo.processInfo.systemUptime

        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = interval
            motion.startAccelerometerUpdates(to: queue) { data, _ in
                guard let d = data else { return }
                log.add("accelerometer", [d.timestamp - start, d.acceleration.x, d.acceleration.y, d.acceleration.z])
            }
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = interval
            motion.startGyroUpdates(to: queue) { data, _ in
                guard let d = data else { return }
                log.add("gyro", [d.timestamp - start, d.rotationRate.x, d.rotationRate.y, d.rotationRate.z])
            }
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = interval
            motion.startMagnetometerUpdates(to: queue) { data, _ in
                guard let d = data else { return }
                log.add("magnetometer", [d.timestamp - start, d.magneticField.x, d.magneticField.y, d.magneticField.z])
            }
        }
        let altimeter = CMAltimeter()
        if barometer {
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
                guard let d = data else { return }
                log.add("barometer", [d.timestamp - start, d.pressure.doubleValue, d.relativeAltitude.doubleValue])
            }
        }

        defer {
            motion.stopAccelerometerUpdates()
            motion.stopGyroUpdates()
            motion.stopMagnetometerUpdates()
            if barometer { altimeter.stopRelativeAltitudeUpdates() }
        }
        try await Task.sleep(for: .seconds(q.seconds))

        var o: [String: JSONValue] = ["seconds": .number(Double(q.seconds)), "hz": .number(Double(q.hz))]
        let available = [
            "accelerometer": motion.isAccelerometerAvailable,
            "gyro": motion.isGyroAvailable,
            "magnetometer": motion.isMagnetometerAvailable,
            "barometer": barometer,
        ]
        for (sensor, isAvailable) in available {
            var s: [String: JSONValue] = ["available": .bool(isAvailable), "samples": .array(log.samples(sensor))]
            if sensor == "barometer", !isAvailable, CMAltimeter.isRelativeAltitudeAvailable() {
                s["reason"] = .string(CMAltimeter.authorizationStatus() == .notDetermined
                    ? "Motion & Fitness not asked yet: Status → Permissions → Ask" : "Motion & Fitness access denied")
            }
            o[sensor] = .object(s)
        }
        return .object(o)
    }
}

/// Thread-safe collector; rounds to keep the result small.
private final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: [[Double]]] = [:]

    func add(_ sensor: String, _ row: [Double]) {
        let rounded = row.map { ($0 * 10_000).rounded() / 10_000 }
        lock.lock()
        rows[sensor, default: []].append(rounded)
        lock.unlock()
    }

    func samples(_ sensor: String) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return (rows[sensor] ?? []).map { .array($0.map(JSONValue.number)) }
    }
}
