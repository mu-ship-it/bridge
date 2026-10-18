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
    /// When the last job started — kept apart from the feed, which Mu can clear.
    private(set) var lastJobAt: Date?
    private(set) var unsentResults = 0
    private(set) var lastSync: Date?
    private(set) var lastSyncMessage = "Never synced"
    /// Newest first, max `activityLimit`, persisted so it survives relaunch.
    private(set) var activity: [ActivityEntry] = []
    private(set) var healthState = "Unknown"
    private(set) var locationState = "Unknown"
    private(set) var pushState = "Not registered"
    private(set) var backgroundRefreshState = "Unknown"

    private let defaults = UserDefaults.standard
    static let activityLimit = 200

    private init() {
        lastPoll = defaults.object(forKey: "status.lastPoll") as? Date
        lastPollMessage = defaults.string(forKey: "status.lastPollMessage") ?? lastPollMessage
        lastSync = defaults.object(forKey: "status.lastSync") as? Date
        lastJobAt = defaults.object(forKey: "status.lastJobAt") as? Date
        lastSyncMessage = defaults.string(forKey: "status.lastSyncMessage") ?? lastSyncMessage
        if let data = defaults.data(forKey: "status.activity"),
           let saved = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            // Anything still "running" was cut off by a relaunch; the server re-offers it after the lease.
            activity = saved.map { e in
                guard e.status == .running else { return e }
                var e = e
                e.status = .failed
                e.summary = "interrupted (app was suspended or quit)"
                return e
            }
        }
        defaults.removeObject(forKey: "status.recentJobs")
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

    func jobStarted(_ job: Job) {
        lastJobAt = Date()
        defaults.set(lastJobAt, forKey: "status.lastJobAt")
        activity.removeAll { $0.id == job.id } // a re-leased job replaces its earlier row
        activity.insert(ActivityEntry(id: job.id, time: Date(), capability: job.capability, note: job.displayNote,
                                      status: .running, summary: ""), at: 0)
        saveActivity()
    }

    func jobFinished(_ job: Job, _ result: JobResult) {
        let summary = ActivitySummary.summarize(job, result)
        let status: ActivityEntry.Status = result.ok ? .done : .failed
        let detail = ActivitySummary.detail(result)
        if let i = activity.firstIndex(where: { $0.id == job.id }) {
            activity[i].status = status
            activity[i].summary = summary
            activity[i].detail = detail
        } else {
            activity.insert(ActivityEntry(id: job.id, time: Date(), capability: job.capability, note: job.displayNote,
                                          status: status, summary: summary, detail: detail), at: 0)
        }
        saveActivity()
    }

    /// Clears finished rows; a job still running keeps its row so its result has somewhere to land.
    func clearActivity() {
        activity.removeAll { $0.status != .running }
        saveActivity()
    }

    private func saveActivity() {
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: "status.activity") }
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
