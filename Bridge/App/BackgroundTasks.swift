import BackgroundTasks
import os

/// BGAppRefreshTask (~every 15 min, at iOS's discretion) and BGProcessingTask (~hourly, network required).
/// Both run one job poll + one health sync. Identifiers must match BGTaskSchedulerPermittedIdentifiers.
enum BackgroundTasks {
    static let refreshID = "\(AppInfo.bundleID).refresh"
    static let processingID = "\(AppInfo.bundleID).processing"
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "bg")

    /// Must be called before didFinishLaunching returns.
    @MainActor
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            MainActor.assumeIsolated { handle(task, trigger: "bg-refresh") }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: .main) { task in
            MainActor.assumeIsolated { handle(task, trigger: "bg-processing") }
        }
    }

    static func scheduleAll() {
        scheduleRefresh()
        scheduleProcessing()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(request)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        submit(request)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected on the simulator (BGTaskSchedulerErrorDomain code 1, unavailable).
            log.notice("BG submit \(request.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private static func handle(_ task: BGTask, trigger: String) {
        if task is BGProcessingTask { scheduleProcessing() } else { scheduleRefresh() }
        let work = Task { await BridgeRuntime.shared.backgroundRun(trigger: trigger) }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}
