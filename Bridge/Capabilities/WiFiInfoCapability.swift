import CoreLocation
import NetworkExtension

/// `wifi.info` → the Wi-Fi network the phone is on: `{connected, ssid?, bssid?, signal?, secure?}`.
/// iOS reveals the network name only to apps with location access (and the Access Wi-Fi
/// Information entitlement). `connected: false` = not on Wi-Fi.
struct WiFiInfoCapability: Capability {
    let name = "wifi.info"

    func run(_ job: Job) async throws -> JSONValue {
        #if targetEnvironment(simulator)
        throw CapabilityError.unavailable("The simulator has no Wi-Fi information")
        #else
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        case .notDetermined: throw CapabilityError.permissionMissing("Location")
        default: throw CapabilityError.permissionDenied("Location")
        }
        guard let network = await NEHotspotNetwork.fetchCurrent() else {
            return .object(["connected": .bool(false)])
        }
        return .object([
            "connected": .bool(true),
            "ssid": .string(network.ssid),
            "bssid": .string(network.bssid),
            // 0–1; iOS reports it only for some networks, 0 means unknown.
            "signal": network.signalStrength > 0 ? .number((network.signalStrength * 100).rounded() / 100) : .null,
            "secure": .bool(network.isSecure),
        ])
        #endif
    }
}
