import SwiftUI

/// "值班中 / On duty": uptime, last job, connection and heartbeat, always visible while duty
/// mode runs — the station says what it is doing.
struct DutyBanner: View {
    private var duty = DutyStation.shared
    private var status = AppStatus.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack(spacing: Theme.Space.s8) {
                    StatusSquare(state: duty.connection.isHealthy ? .done : .failed)
                        .font(Theme.Role.subhead)
                    Text(duty.isOnDuty ? "On duty" : "Duty on · waiting for a window")
                        .font(Theme.Role.subhead.bold())
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if let since = duty.onDutySince {
                        Text(DutyStation.uptimeText(context.date.timeIntervalSince(since)))
                            .font(Theme.Role.subhead.bold())
                            .monospacedDigit()
                            .accessibilityLabel("Uptime \(DutyStation.uptimeText(context.date.timeIntervalSince(since)))")
                    }
                }
                Text(connectionLine(at: context.date)).font(Theme.Role.meta)
                Text("Last job: \(ago(status.lastJobAt, at: context.date))").font(Theme.Role.meta).foregroundStyle(Theme.dim)
                Text(heartbeatLine(at: context.date)).font(Theme.Role.meta)
                    .foregroundStyle(duty.lastHeartbeatError == nil ? Theme.dim : Theme.red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func connectionLine(at now: Date) -> String {
        // The state's English label goes to the box in heartbeats; this is its display form.
        let label = if case .retrying(_, let failures) = duty.connection {
            String(localized: "Box unreachable — retrying (\(failures) failed in a row)")
        } else {
            duty.connection.label.localizedForDisplay
        }
        if case .retrying(let at, _) = duty.connection, at > now {
            return String(localized: "\(label) in \(Int(at.timeIntervalSince(now).rounded(.up)))s")
        }
        return label
    }

    private func heartbeatLine(at now: Date) -> String {
        if let error = duty.lastHeartbeatError { return String(localized: "Heartbeat failed: \(error)") }
        return String(localized: "Heartbeat to box: \(ago(duty.lastHeartbeat, at: now)) (every 5 min)")
    }

    private func ago(_ date: Date?, at now: Date) -> String {
        guard let date else { return String(localized: "none yet") }
        let seconds = now.timeIntervalSince(date)
        return seconds < 5 ? String(localized: "just now") : String(localized: "\(DutyStation.uptimeText(seconds)) ago")
    }
}
