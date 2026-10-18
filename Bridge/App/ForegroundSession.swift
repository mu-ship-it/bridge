import SwiftUI
import UIKit

/// The app-wide foreground connection. With several windows (iPad Stage Manager, Split View,
/// the board window) each scene reports its phase here, and one poller runs while at least one
/// window is in the foreground — never one per window, never with none. Duty mode rides on the
/// same switch: on while a window is up and the toggle is on, off the moment either stops.
@MainActor
final class ForegroundSession {
    static let shared = ForegroundSession()

    private var scenes: Set<UUID> = []
    private var poller: Task<Void, Never>?
    private var heartbeats: Task<Void, Never>?
    private let duty = DutyStation.shared

    private init() {
        duty.onEnabledChange = { [weak self] in self?.reconcile() }
    }

    /// `.inactive` (Control Center, a system alert, Stage Manager focus moving to another app's
    /// window) still counts as foreground: the window is on screen. Only `.background` stops it.
    func update(scene: UUID, phase: ScenePhase) {
        if phase == .background { scenes.remove(scene) } else { scenes.insert(scene) }
        reconcile()
    }

    func remove(scene: UUID) {
        scenes.remove(scene)
        reconcile()
    }

    private func reconcile() {
        let foreground = !scenes.isEmpty
        duty.windows = scenes.count

        if foreground, poller == nil {
            poller = Task {
                await AppStatus.shared.refreshPermissions()
                // Cancelling this task cancels the in-flight request: nothing polls once hidden.
                await ForegroundPoller(loop: BridgeRuntime.shared.jobLoop) { state in
                    DutyStation.shared.connection = state
                }.run()
            }
        } else if !foreground, let task = poller {
            task.cancel()
            poller = nil
            duty.connection = .idle
        }

        let onDuty = foreground && duty.enabled
        UIApplication.shared.isIdleTimerDisabled = onDuty
        if onDuty, heartbeats == nil {
            duty.begin()
            heartbeats = Task { [duty] in
                await duty.post(duty.heartbeat(.start))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(DutyStation.heartbeatInterval))
                    if Task.isCancelled { return }
                    await duty.post(duty.heartbeat(.interval))
                }
            }
        } else if !onDuty, let task = heartbeats {
            task.cancel()
            heartbeats = nil
            let goodbye = duty.heartbeat(.stop(foreground ? "duty mode turned off" : "白手套 left the screen"))
            duty.end()
            Task { [duty] in await duty.post(goodbye) }
        }
    }
}
