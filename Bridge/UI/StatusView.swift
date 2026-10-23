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
                    Section { DutyBanner() }.boxRows()
                }
                if compact && !showDetails {
                    activitySection
                } else {
                    details
                }
            }
            .boxList()
            .navigationTitle("Bridge")
            .toolbar {
                if compact {
                    Button(showDetails ? "Feed only" : "Details") { showDetails.toggle() }
                        .buttonStyle(.box())
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
        Section {
            row("Last poll", status.lastPoll)
            LabeledContent("Result", value: status.lastPollMessage)
            LabeledContent("Pending jobs") { Text("\(status.pendingJobs)").font(Theme.Role.data) }
            if status.unsentResults > 0 {
                LabeledContent("Unsent results") {
                    Text("\(status.unsentResults)").font(Theme.Role.data).foregroundStyle(Theme.red)
                }
            }
            Button("Poll now") { run { await BridgeRuntime.shared.jobLoop.pollOnce(trigger: "button") } }
                .buttonStyle(.box())
        } header: {
            header("Job loop · 轮询")
        }
        .boxRows()
        activitySection
        Section {
            row("Last sync", status.lastSync)
            LabeledContent("Result", value: status.lastSyncMessage)
            Button("Sync now") { run { await BridgeRuntime.shared.healthSync.syncNow(trigger: "button") } }
                .buttonStyle(.box())
        } header: {
            header("Health sync · 健康")
        }
        .boxRows()
        permissionsSection
        Section {
            ForEach(BridgeRuntime.shared.dispatcher.names, id: \.self) { Text($0).font(Theme.Role.data) }
        } header: {
            header("Capabilities · 能力")
        }
        .boxRows()
    }

    // MARK: Activity

    private var activitySection: some View {
        let shown = filter.apply(status.activity)
        return Section {
            HStack(spacing: Theme.Space.s8) {
                ForEach(ActivityFilter.allCases) { chip in
                    let count = chip.apply(status.activity).count
                    Button { filter = chip } label: {
                        HStack(spacing: Theme.Space.s4) {
                            Text(chip.title)
                            Text("\(count)").font(Theme.Role.meta.bold())
                        }
                    }
                    .buttonStyle(.box(selected: filter == chip))
                    .accessibilityAddTraits(filter == chip ? .isSelected : [])
                }
                Spacer()
                Button("Clear", role: .destructive) { confirmClear = true }
                    .buttonStyle(.box(color: Theme.dim))
                    .disabled(status.activity.allSatisfy { $0.status == .running })
            }
            if shown.isEmpty {
                Text(status.activity.isEmpty ? "Nothing yet." : "Nothing \(filter.rawValue).").foregroundStyle(Theme.dim)
            }
            ForEach(shown) { ActivityRow(entry: $0) }
        } header: {
            header("Activity · 动态")
        }
        .boxRows()
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
                    VStack(alignment: .leading, spacing: Theme.Space.s4) {
                        Text(kind.title)
                        Text(kind.usedBy).font(Theme.Role.prose).foregroundStyle(Theme.dim)
                        Text(state).boxLabel(color: color(state))
                    }
                    Spacer()
                    switch kind.action(for: state) {
                    case .ask:
                        Button("Ask") { run { await kind.request(); await refreshPermissions() } }
                            .buttonStyle(.box())
                    case .openSettings:
                        Button("Settings") { openSettings() }
                            .buttonStyle(.box())
                    case .none:
                        EmptyView()
                    }
                }
            }
            LabeledContent("Push", value: status.pushState)
            LabeledContent("Background refresh", value: status.backgroundRefreshState)
        } header: {
            header("Permissions · 权限")
        } footer: {
            Text("iOS asks for each permission only once; after “Don't Allow” the switch lives in Settings. Home accessories are added and paired in Apple's Home app, not here: 白手套 sees only what the Home app already has. Unlocking, opening a garage door or disarming always asks you first.")
                .font(Theme.Role.prose).foregroundStyle(Theme.dim)
        }
        .boxRows()
    }

    private func color(_ state: String) -> Color {
        switch state {
        case PermissionState.granted, "Always": Theme.text
        case PermissionState.denied, "Denied": Theme.red
        default: Theme.dim
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
            Group {
                if let date { Text(date, style: .relative) + Text(" ago") } else { Text("Never") }
            }
            .font(Theme.Role.data)
            .monospacedDigit()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).boxLabel()
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

extension ActivityEntry.Status {
    var square: StatusSquare.State {
        switch self {
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }
}

/// One activity-feed row: time · capability · status, then the agent's note and a one-line result.
private struct ActivityRow: View {
    let entry: ActivityEntry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s8) {
            StatusSquare(state: entry.status.square)
                .font(Theme.Role.meta)
                .padding(.top, Theme.Space.s4)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack(spacing: Theme.Space.s0) {
                    Text("\(entry.time.formatted(date: .omitted, time: .shortened)) · \(entry.capability) · ")
                    Text(entry.status.rawValue).textCase(.uppercase)
                }
                .font(Theme.Role.meta)
                .lineLimit(1)
                .foregroundStyle(entry.status == .done ? Theme.dim : Theme.red)
                if entry.capability == "agent.say" {
                    Text(entry.summary)
                } else {
                    if let note = entry.note { Text(note) }
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
                    }
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
                        .foregroundStyle(copied ? Theme.text : Theme.dim)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy result")
            }
        }
    }
}
