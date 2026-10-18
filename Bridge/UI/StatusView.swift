import SwiftUI

/// Narrow iPad windows (a small Stage Manager window, the slim side of Split View) get the
/// feed only; an iPhone keeps the full screen, since that is its only view.
enum StatusLayout {
    static let compactBelow: CGFloat = 520

    static func isCompact(width: CGFloat, idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .pad && width > 0 && width < compactBelow
    }
}

struct StatusView: View {
    private var status = AppStatus.shared
    private var duty = DutyStation.shared
    @State private var width: CGFloat = 0
    @State private var showDetails = false
    @State private var busy = false
    @State private var filter = ActivityFilter.all
    @State private var confirmClear = false
    @State private var permissions: [PermissionKind: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                if duty.enabled {
                    Section { DutyBanner() }
                }
                if compact && !showDetails {
                    activitySection
                } else {
                    details
                }
            }
            .navigationTitle("Bridge")
            .toolbar {
                if compact {
                    Button(showDetails ? "Feed only" : "Details") { showDetails.toggle() }
                }
            }
            .disabled(busy)
            .refreshable { await refreshPermissions() }
            .task { await refreshPermissions() }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    private var compact: Bool {
        StatusLayout.isCompact(width: width, idiom: UIDevice.current.userInterfaceIdiom)
    }

    @ViewBuilder private var details: some View {
        Section("Job loop") {
            row("Last poll", status.lastPoll)
            LabeledContent("Result", value: status.lastPollMessage)
            LabeledContent("Pending jobs", value: "\(status.pendingJobs)")
            if status.unsentResults > 0 {
                LabeledContent("Unsent results", value: "\(status.unsentResults)")
            }
            Button("Poll now") { run { await BridgeRuntime.shared.jobLoop.pollOnce(trigger: "button") } }
        }
        activitySection
        Section("Health sync") {
            row("Last sync", status.lastSync)
            LabeledContent("Result", value: status.lastSyncMessage)
            Button("Sync now") { run { await BridgeRuntime.shared.healthSync.syncNow(trigger: "button") } }
        }
        permissionsSection
        Section("Capabilities") {
            ForEach(BridgeRuntime.shared.dispatcher.names, id: \.self) { Text($0).monospaced() }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        let shown = filter.apply(status.activity)
        return Section {
            HStack(spacing: 8) {
                ForEach(ActivityFilter.allCases) { chip in
                    let count = chip.apply(status.activity).count
                    Button("\(chip.title) \(count)") { filter = chip }
                        .buttonStyle(.bordered)
                        .tint(filter == chip ? .accentColor : .secondary)
                        .controlSize(.small)
                        .accessibilityAddTraits(filter == chip ? .isSelected : [])
                }
                Spacer()
                Button("Clear", role: .destructive) { confirmClear = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(status.activity.allSatisfy { $0.status == .running })
            }
            if shown.isEmpty {
                Text(status.activity.isEmpty ? "Nothing yet" : "Nothing \(filter.rawValue)").foregroundStyle(.secondary)
            }
            ForEach(shown) { ActivityRow(entry: $0) }
        } header: {
            Text("Activity")
        }
        .confirmationDialog("Clear the activity feed?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear finished jobs", role: .destructive) { status.clearActivity() }
        } message: {
            Text("Running jobs stay. The box keeps its own record of every job and result.")
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(PermissionKind.allCases) { kind in
                let state = permissions[kind] ?? "…"
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.usedBy).font(.caption).foregroundStyle(.secondary)
                        Text(state).font(.caption).foregroundStyle(color(state))
                    }
                    Spacer()
                    switch kind.action(for: state) {
                    case .ask:
                        Button("Ask") { run { await kind.request(); await refreshPermissions() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    case .openSettings:
                        Button("Open Settings") { openSettings() }
                            .buttonStyle(.bordered).controlSize(.small)
                    case .none:
                        EmptyView()
                    }
                }
            }
            LabeledContent("Push", value: status.pushState)
            LabeledContent("Background refresh", value: status.backgroundRefreshState)
        } header: {
            Text("Permissions")
        } footer: {
            Text("iOS asks for each permission only once; after “Don't Allow” the switch lives in Settings. Home accessories are added and paired in Apple's Home app, not here: 白手套 sees only what the Home app already has. Unlocking, opening a garage door or disarming always asks you first.")
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case PermissionState.granted, "Always": .green
        case PermissionState.denied, "Denied": .red
        default: .secondary
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func refreshPermissions() async {
        await status.refreshPermissions()
        for kind in PermissionKind.allCases { permissions[kind] = await kind.state() }
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
            await refreshPermissions()
            busy = false
        }
    }
}

/// One activity-feed row: time · capability · status, then the agent's note and a one-line result.
private struct ActivityRow: View {
    let entry: ActivityEntry
    @State private var copied = false

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
            Spacer(minLength: 0)
            if entry.status != .running {
                Button {
                    UIPasteboard.general.string = entry.copyText
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy result")
            }
        }
    }
}
