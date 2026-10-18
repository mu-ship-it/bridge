import SwiftUI

/// "值班中 / On duty": uptime, last job, connection and heartbeat, always visible while duty
/// mode runs — the station says what it is doing.
struct DutyBanner: View {
    private var duty = DutyStation.shared
    private var status = AppStatus.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(duty.connection.isHealthy ? .green : .orange).frame(width: 9, height: 9)
                    Text(duty.isOnDuty ? "值班中 / On duty" : "Duty mode on — waiting for a window")
                        .font(.headline)
                    Spacer(minLength: 0)
                    if let since = duty.onDutySince {
                        Text(DutyStation.uptimeText(context.date.timeIntervalSince(since)))
                            .font(.headline.monospacedDigit())
                            .accessibilityLabel("Uptime \(DutyStation.uptimeText(context.date.timeIntervalSince(since)))")
                    }
                }
                Text(connectionLine(at: context.date)).font(.caption)
                Text("Last job: " + ago(status.lastJobAt, at: context.date)).font(.caption).foregroundStyle(.secondary)
                Text(heartbeatLine(at: context.date)).font(.caption)
                    .foregroundStyle(duty.lastHeartbeatError == nil ? Color.secondary : Color.red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func connectionLine(at now: Date) -> String {
        if case .retrying(let at, _) = duty.connection, at > now {
            return duty.connection.label + " in \(Int(at.timeIntervalSince(now).rounded(.up)))s"
        }
        return duty.connection.label
    }

    private func heartbeatLine(at now: Date) -> String {
        if let error = duty.lastHeartbeatError { return "Heartbeat failed: \(error)" }
        return "Heartbeat to box: " + ago(duty.lastHeartbeat, at: now) + " (every 5 min)"
    }

    private func ago(_ date: Date?, at now: Date) -> String {
        guard let date else { return "none yet" }
        let seconds = now.timeIntervalSince(date)
        return seconds < 5 ? "just now" : DutyStation.uptimeText(seconds) + " ago"
    }
}
