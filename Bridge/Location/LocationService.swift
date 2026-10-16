import CoreLocation

/// One-shot fixes for `location.now`, plus significant-change monitoring purely as a background keep-alive.
/// Never starts continuous GPS.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation, Error>] = []
    /// Called when a significant-change update wakes us (and nobody asked for a fix).
    var onSignificantChange: (@MainActor () -> Void)?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationDescription: String {
        switch manager.authorizationStatus {
        case .notDetermined: "Not requested yet"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorizedWhenInUse: "When in use (keep-alive needs Always)"
        case .authorizedAlways: "Always"
        @unknown default: "Unknown"
        }
    }

    /// First call shows the when-in-use prompt (provisional Always); a second call escalates to Always.
    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startKeepAlive() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable(),
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    func oneShot(timeout: Duration = .seconds(20)) async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw CapabilityError(code: "permission_denied", message: "Location access denied")
        case .notDetermined:
            throw CapabilityError(code: "permission_missing", message: "Location not requested yet — open Bridge → Status → Request Location")
        default: break
        }
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(CapabilityError(code: "timeout", message: "No location fix within \(timeout)")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }

    // Delegate callbacks arrive on the main run loop (manager was created on main).

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated {
            if waiters.isEmpty { onSignificantChange?() } else { finish(.success(last)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            finish(.failure(CapabilityError(code: "location_failed", message: message)))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            AppStatus.shared.setLocationState(authorizationDescription)
            startKeepAlive()
        }
    }
}
