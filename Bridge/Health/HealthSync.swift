import Foundation
import os

/// Base behaviour 2: push HealthKit samples added since the last successful sync to `POST /hk/ingest`.
/// Uses one HKQueryAnchor per type; anchors are only advanced after the box returns 2xx,
/// so a failed upload is retried next time. First run looks back `initialLookback`.
actor HealthSync {
    static let initialLookback: TimeInterval = 7 * 24 * 3600
    /// Per type per run; a backlog drains over several runs.
    static let perTypeLimit = 2000

    private var running = false
    private let health = HealthService.shared
    private let log = Logger(subsystem: AppInfo.bundleID, category: "sync")

    @discardableResult
    func syncNow(trigger: String = "manual") async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }

        guard let config = ConfigStore.load() else {
            await AppStatus.shared.recordSync(success: false, message: "Not configured")
            return false
        }
        guard health.isAvailable else {
            await AppStatus.shared.recordSync(success: false, message: "HealthKit unavailable")
            return false
        }
        do {
            let fallbackStart = Date().addingTimeInterval(-Self.initialLookback)
            var batch = HealthBatch()
            var anchors: [String: Data] = [:]

            for metric in HealthMetric.allCases {
                let page = try await health.newQuantities(metric, anchor: anchor(metric.rawValue), fallbackStart: fallbackStart, limit: Self.perTypeLimit)
                batch.quantities[metric] = page.items
                anchors[metric.rawValue] = page.anchor
            }
            let sleep = try await health.newSleep(anchor: anchor("sleep_analysis"), fallbackStart: fallbackStart, limit: Self.perTypeLimit)
            batch.sleep = sleep.items
            anchors["sleep_analysis"] = sleep.anchor
            let workouts = try await health.newWorkouts(anchor: anchor("workouts"), fallbackStart: fallbackStart, limit: Self.perTypeLimit)
            batch.workouts = workouts.items
            anchors["workouts"] = workouts.anchor

            if !batch.isEmpty {
                try await BoxClient(config: config).ingest(try HealthIngestMapper.encode(batch))
            }
            for (key, data) in anchors { UserDefaults.standard.set(data, forKey: "hk.anchor.\(key)") }
            log.info("sync (\(trigger, privacy: .public)): \(batch.summary, privacy: .public)")
            await AppStatus.shared.recordSync(success: true, message: batch.summary)
            return true
        } catch {
            log.error("sync failed: \(error.localizedDescription, privacy: .public)")
            await AppStatus.shared.recordSync(success: false, message: error.localizedDescription)
            return false
        }
    }

    private func anchor(_ key: String) -> Data? {
        UserDefaults.standard.data(forKey: "hk.anchor.\(key)")
    }
}
