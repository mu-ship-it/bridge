import SwiftUI
import WidgetKit

@main
struct BridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        BridgeActivityWidget()
    }
}

struct BridgeEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// The app's snapshot first (instant, no network), then the box's own feed when the shared
/// Keychain token is reachable — the box knows about jobs the phone has not polled yet.
struct BridgeProvider: TimelineProvider {
    static let refresh: TimeInterval = 15 * 60
    static let fetchTimeout: TimeInterval = 5

    func placeholder(in context: Context) -> BridgeEntry {
        BridgeEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BridgeEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : (SharedStore.loadSnapshot() ?? .sample)
        completion(BridgeEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BridgeEntry>) -> Void) {
        let local = SharedStore.loadSnapshot()
        let done = Completion(call: completion)
        Task {
            let snapshot = await Self.fetchFeed(local: local) ?? local ?? WidgetSnapshot(rows: [], agentLine: nil, lastPoll: nil, lastHealth: nil)
            let now = Date()
            done.call(Timeline(entries: [BridgeEntry(date: now, snapshot: snapshot)],
                                policy: .after(now.addingTimeInterval(Self.refresh))))
        }
    }

    static func fetchFeed(local: WidgetSnapshot?) async -> WidgetSnapshot? {
        guard let box = SharedStore.boxCredentials(),
              var components = URLComponents(url: box.url.appending(path: "bridge/feed"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [.init(name: "device", value: box.device),
                                 .init(name: "limit", value: String(WidgetSnapshot.rowLimit))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
        request.setValue("Bearer \(box.token)", forHTTPHeaderField: "Authorization")
        request.setValue(box.device, forHTTPHeaderField: "X-Bridge-Device")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let feed = try? JSONDecoder().decode(WidgetSnapshot.Feed.self, from: data) else { return nil }
        return WidgetSnapshot(feed: feed, local: local)
    }
}

/// WidgetKit's completion handlers are not marked Sendable, but may be called from any thread.
private struct Completion<Value>: @unchecked Sendable {
    let call: (Value) -> Void
}

struct BridgeActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BridgeActivity", provider: BridgeProvider()) { entry in
            BridgeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "bridge-widget://status"))
        }
        .configurationDisplayName("白手套")
        .description("What your agent is doing: its last line and the latest jobs.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: Views

struct BridgeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BridgeEntry

    var body: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline: Text(entry.snapshot.rows.first?.title ?? entry.snapshot.headline).lineLimit(1)
        default: SmallView(entry: entry)
        }
    }
}

extension WidgetSnapshot.Dot {
    var color: Color {
        switch self {
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .stale: .gray
        }
    }
}

private struct StatusDot: View {
    let dot: WidgetSnapshot.Dot
    var body: some View {
        Circle().fill(dot.color).frame(width: 8, height: 8)
            .accessibilityLabel(Text(dot.rawValue))
    }
}

private func ago(_ date: Date) -> String {
    date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
}

private struct SmallView: View {
    let entry: BridgeEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: 6) {
            Text("白手套").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(snapshot.headline)
                .font(.subheadline)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let row = snapshot.rows.first {
                HStack(spacing: 6) {
                    StatusDot(dot: snapshot.dot(for: row, now: entry.date))
                    Text(ago(snapshot.time(of: row)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct MediumView: View {
    let entry: BridgeEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("白手套").font(.caption.weight(.semibold))
                Spacer()
                if let line = snapshot.lastHealth {
                    Text(line).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if snapshot.rows.isEmpty {
                Text(snapshot.headline).font(.subheadline)
            }
            ForEach(snapshot.rows.prefix(3)) { row in
                HStack(spacing: 6) {
                    StatusDot(dot: snapshot.dot(for: row, now: entry.date))
                    Text(row.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ago(snapshot.time(of: row)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RectangularView: View {
    let entry: BridgeEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: 2) {
            if let row = snapshot.rows.first {
                HStack(spacing: 4) {
                    StatusDot(dot: snapshot.dot(for: row, now: entry.date))
                    Text("\(row.status.rawValue) · \(ago(snapshot.time(of: row)))")
                        .font(.caption2)
                }
                Text(row.title).font(.headline).lineLimit(2)
            } else {
                Text(snapshot.headline).font(.headline).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemSmall) {
    BridgeActivityWidget()
} timeline: {
    BridgeEntry(date: Date(), snapshot: .sample)
}

#Preview(as: .systemMedium) {
    BridgeActivityWidget()
} timeline: {
    BridgeEntry(date: Date(), snapshot: .sample)
}

#Preview(as: .accessoryRectangular) {
    BridgeActivityWidget()
} timeline: {
    BridgeEntry(date: Date(), snapshot: .sample)
}

#Preview(as: .accessoryInline) {
    BridgeActivityWidget()
} timeline: {
    BridgeEntry(date: Date(), snapshot: .sample)
}
