import SwiftUI

struct StatusView: View {
    private var status = AppStatus.shared
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("Job loop") {
                    row("Last poll", status.lastPoll)
                    LabeledContent("Result", value: status.lastPollMessage)
                    LabeledContent("Pending jobs", value: "\(status.pendingJobs)")
                    if status.unsentResults > 0 {
                        LabeledContent("Unsent results", value: "\(status.unsentResults)")
                    }
                    Button("Poll now") { run { await BridgeRuntime.shared.jobLoop.pollOnce(trigger: "button") } }
                }
                Section("Activity") {
                    if status.activity.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(status.activity) { ActivityRow(entry: $0) }
                }
                Section("Health sync") {
                    row("Last sync", status.lastSync)
                    LabeledContent("Result", value: status.lastSyncMessage)
                    Button("Sync now") { run { await BridgeRuntime.shared.healthSync.syncNow(trigger: "button") } }
                }
                Section("Permissions") {
                    LabeledContent("Health", value: status.healthState)
                    LabeledContent("Location", value: status.locationState)
                    LabeledContent("Push", value: status.pushState)
                    LabeledContent("Background refresh", value: status.backgroundRefreshState)
                    Button("Request Health access") {
                        run { try? await HealthService.shared.requestAuthorization() }
                    }
                    Button("Request Location (Always)") { LocationService.shared.requestAuthorization() }
                    Button("Request Notifications") { run { _ = try? await NotifyShowCapability.requestAuthorization() } }
                    Button("Request Calendar") { run { _ = await EventKitAccess.requestCalendar() } }
                    Button("Request Reminders") { run { _ = await EventKitAccess.requestReminders() } }
                    Button("Request Contacts") { run { _ = await ContactsSearchCapability.requestAuthorization() } }
                    Button("Request Photos") { run { _ = await PhotosRecentCapability.requestAuthorization() } }
                    Button("Request Motion") { run { await MotionTodayCapability.requestAuthorization() } }
                }
                Section("Capabilities") {
                    ForEach(BridgeRuntime.shared.dispatcher.names, id: \.self) { Text($0).monospaced() }
                }
            }
            .navigationTitle("Bridge")
            .disabled(busy)
            .refreshable { await status.refreshPermissions() }
        }
    }

    private func row(_ label: String, _ date: Date?) -> some View {
        LabeledContent(label) {
            if let date { Text(date, style: .relative) + Text(" ago") } else { Text("Never") }
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task {
            await action()
            await status.refreshPermissions()
            busy = false
        }
    }
}

/// One activity-feed row: time · capability · status, then the agent's note and a one-line result.
private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch entry.status {
            case .running: ProgressView()
            case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.time.formatted(date: .omitted, time: .shortened)) · \(entry.capability) · \(entry.status.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if entry.capability == "agent.say" {
                    Text(entry.summary)
                } else {
                    if let note = entry.note { Text(note) }
                    if !entry.summary.isEmpty { Text(entry.summary).font(.caption).lineLimit(1) }
                }
            }
        }
    }
}
