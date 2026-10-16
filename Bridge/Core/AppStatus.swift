import Foundation
import Observation
import UIKit

/// What the Status screen shows. Small, persisted in UserDefaults (no secrets, no health data).
@MainActor @Observable
final class AppStatus {
    static let shared = AppStatus()

    private(set) var lastPoll: Date?
    private(set) var lastPollMessage = "Never polled"
    private(set) var pendingJobs = 0
    private(set) var unsentResults = 0
    private(set) var lastSync: Date?
    private(set) var lastSyncMessage = "Never synced"
    private(set) var recentJobs: [String] = []
    private(set) var healthState = "Unknown"
    private(set) var locationState = "Unknown"
    private(set) var pushState = "Not registered"
    private(set) var backgroundRefreshState = "Unknown"

    private let defaults = UserDefaults.standard

    private init() {
        lastPoll = defaults.object(forKey: "status.lastPoll") as? Date
        lastPollMessage = defaults.string(forKey: "status.lastPollMessage") ?? lastPollMessage
        lastSync = defaults.object(forKey: "status.lastSync") as? Date
        lastSyncMessage = defaults.string(forKey: "status.lastSyncMessage") ?? lastSyncMessage
        recentJobs = defaults.stringArray(forKey: "status.recentJobs") ?? []
    }

    func recordPoll(success: Bool, message: String, unsent: Int) {
        if success {
            lastPoll = Date()
            defaults.set(lastPoll, forKey: "status.lastPoll")
        }
        lastPollMessage = success ? message : "Error: \(message)"
        unsentResults = unsent
        defaults.set(lastPollMessage, forKey: "status.lastPollMessage")
    }

    func setPending(_ count: Int) { pendingJobs = max(0, count) }

    func recordJob(_ result: JobResult, capability: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let line = "\(time) \(capability) \(result.ok ? "ok" : "✗ \(result.error?.code ?? "error")")"
        recentJobs = Array(([line] + recentJobs).prefix(20))
        defaults.set(recentJobs, forKey: "status.recentJobs")
    }

    func recordSync(success: Bool, message: String) {
        if success {
            lastSync = Date()
            defaults.set(lastSync, forKey: "status.lastSync")
        }
        lastSyncMessage = success ? message : "Error: \(message)"
        defaults.set(lastSyncMessage, forKey: "status.lastSyncMessage")
    }

    func setPushState(_ state: String) { pushState = state }
    func setLocationState(_ state: String) { locationState = state }

    func refreshPermissions() async {
        healthState = await HealthService.shared.authorizationSummary()
        locationState = LocationService.shared.authorizationDescription
        backgroundRefreshState = switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "Available"
        case .denied: "Denied (Settings → General → Background App Refresh)"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
        if UIApplication.shared.isRegisteredForRemoteNotifications, pushState == "Not registered" {
            pushState = "Registered (token pending)"
        }
    }
}
