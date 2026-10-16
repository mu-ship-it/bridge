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
                }
                Section("Capabilities") {
                    ForEach(BridgeRuntime.shared.dispatcher.names, id: \.self) { Text($0).monospaced() }
                }
                if !status.recentJobs.isEmpty {
                    Section("Recent jobs") {
                        ForEach(status.recentJobs, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
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
