import Foundation
import Observation

/// Duty mode (值班): an iPad parked in a small Stage Manager window, plugged in and never
/// locking, is always in the foreground — so the long poll never stops and jobs never wait.
/// Duty mode only adds what such a station needs on top of the normal foreground connection:
/// the screen stays awake, the banner says so, and the box hears a heartbeat every 5 minutes.
/// It never runs anything in the background; ForegroundSession ends it when the last window leaves.
@MainActor @Observable
final class DutyStation {
    static let shared = DutyStation()
    nonisolated static let heartbeatInterval: TimeInterval = 300
    private static let enabledKey = "duty.enabled"

    /// The Settings switch. Persisted; takes effect the moment it changes.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            onEnabledChange()
        }
    }
    @ObservationIgnored var onEnabledChange: @MainActor () -> Void = {}

    /// Start of the current unbroken on-duty stretch; nil when not on duty.
    private(set) var onDutySince: Date?
    /// Set by ForegroundSession from the poller's reports.
    var connection = ConnectionState.idle
    /// Windows of this app currently in the foreground.
    var windows = 0
    private(set) var lastHeartbeat: Date?
    private(set) var lastHeartbeatError: String?

    var isOnDuty: Bool { onDutySince != nil }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func begin(now: Date = Date()) { onDutySince = now }
    func end() { onDutySince = nil }

    // MARK: Heartbeat

    enum HeartbeatReason: Equatable, Sendable {
        case start, interval
        case stop(String)

        var label: String {
            switch self {
            case .start: "start"
            case .interval: "interval"
            case .stop(let why): "stop: \(why)"
            }
        }
    }

    /// A `device.info`-shaped report plus the duty fields, as a `heartbeat` event.
    func heartbeat(_ reason: HeartbeatReason, now: Date = Date()) -> DeviceEvent {
        Self.heartbeatEvent(base: DeviceInfoCapability.snapshot(), reason: reason, since: onDutySince,
                            connection: connection, lastJob: AppStatus.shared.lastJobAt, windows: windows, now: now)
    }

    nonisolated static func heartbeatEvent(base: [String: JSONValue], reason: HeartbeatReason, since: Date?,
                                           connection: ConnectionState, lastJob: Date?, windows: Int,
                                           now: Date) -> DeviceEvent {
        var payload = base
        let onDuty = if case .stop = reason { false } else { true }
        payload["duty"] = .bool(onDuty)
        payload["reason"] = .string(reason.label)
        payload["on_duty_since"] = since.map { .string(ISO.string($0)) } ?? .null
        payload["uptime_s"] = since.map { .number(now.timeIntervalSince($0).rounded()) } ?? .null
        payload["connection"] = .string(connection.label)
        payload["last_job_at"] = lastJob.map { .string(ISO.string($0)) } ?? .null
        payload["foreground_windows"] = .number(Double(windows))
        payload["heartbeat_interval_s"] = .number(heartbeatInterval)
        let note = switch reason {
        case .start: "On duty: 白手套 is on screen and will report every 5 minutes while it stays there"
        case .interval: "On duty: 5-minute heartbeat from 白手套 on screen"
        case .stop(let why): "Off duty: \(why)"
        }
        return DeviceEvent(type: "heartbeat", ts: ISO.string(now), payload: .object(payload), note: note)
    }

    func post(_ event: DeviceEvent) async {
        guard let config = ConfigStore.load() else {
            lastHeartbeatError = BoxError.notConfigured.localizedDescription
            return
        }
        do {
            // Outside the caller's cancellation: the "off duty" beat is sent as the window leaves.
            try await BackgroundTime.run("duty heartbeat") { try await BoxClient(config: config).postEvents([event]) }
            lastHeartbeat = Date()
            lastHeartbeatError = nil
        } catch {
            lastHeartbeatError = error.localizedDescription
        }
    }

    // MARK: Display

    /// "45s", "12m", "3h 04m", "2d 3h" — a station runs for days.
    nonisolated static func uptimeText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (d, h, m) = (s / 86_400, s % 86_400 / 3_600, s % 3_600 / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h " + String(format: "%02dm", m) }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
