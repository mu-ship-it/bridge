import Foundation
import os

/// Wires capabilities, the job loop and health sync together. One instance per process.
@MainActor
final class BridgeRuntime {
    static let shared = BridgeRuntime()

    let dispatcher: JobDispatcher
    let jobLoop: JobLoop
    let healthSync = HealthSync()
    private let log = Logger(subsystem: AppInfo.bundleID, category: "runtime")

    private init() {
        dispatcher = JobDispatcher(CapabilityRegistry.all)
        jobLoop = JobLoop(dispatcher: dispatcher)
    }

    func start() {
        LocationService.shared.onSignificantChange = { [weak self] in
            guard let self else { return }
            Task { await self.jobLoop.pollOnce(trigger: "location") }
        }
        LocationService.shared.startKeepAlive()
        BackgroundTasks.scheduleAll()
        Task { await AppStatus.shared.refreshPermissions() }
    }

    /// Body of BG refresh / processing tasks.
    func backgroundRun(trigger: String) async {
        await jobLoop.pollOnce(trigger: trigger)
        await healthSync.syncNow(trigger: trigger)
    }

    /// Silent push: one poll; `"bridge":"sync"` in the payload also runs a health sync.
    func handleSilentPush(wantsSync: Bool) async -> Bool {
        let didWork = await jobLoop.pollOnce(trigger: "push")
        if wantsSync { return await healthSync.syncNow(trigger: "push") || didWork }
        return didWork
    }

    func registerPushToken(_ hexToken: String) async {
        guard let config = ConfigStore.load() else {
            AppStatus.shared.setPushState("Token received; box not configured")
            return
        }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let registration = DeviceRegistration(device: config.deviceId, apnsToken: hexToken, apnsEnvironment: environment,
                                              appVersion: AppInfo.version, capabilities: dispatcher.names)
        do {
            try await BoxClient(config: config).registerDevice(registration)
            AppStatus.shared.setPushState("Registered with box")
        } catch {
            log.error("device registration failed: \(error.localizedDescription, privacy: .public)")
            AppStatus.shared.setPushState("Box registration failed: \(error.localizedDescription)")
        }
    }
}
