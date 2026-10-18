import Foundation
import UIKit

/// Battery, model, iOS version, app version, last sync time. No params.
struct DeviceInfoCapability: Capability {
    let name = "device.info"

    func run(_ job: Job) async throws -> JSONValue {
        await MainActor.run { .object(Self.snapshot()) }
    }

    /// The `device.info` fields; the duty heartbeat sends the same shape plus its own.
    @MainActor
    static func snapshot() -> [String: JSONValue] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        let status = AppStatus.shared
        return [
            "battery_level": device.batteryLevel < 0 ? .null : .number(HealthIngestMapper.round(Double(device.batteryLevel))),
            "battery_state": .string(state),
            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "model": .string(device.model),
            "model_identifier": .string(Self.modelIdentifier),
            "system_name": .string(device.systemName),
            "system_version": .string(device.systemVersion),
            "app_version": .string(AppInfo.version),
            "last_sync": status.lastSync.map { .string(ISO.string($0)) } ?? .null,
            "last_poll": status.lastPoll.map { .string(ISO.string($0)) } ?? .null,
            "background_refresh": .string(status.backgroundRefreshState),
        ]
    }

    /// e.g. "iPhone17,1"; on the simulator, the simulated model.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
