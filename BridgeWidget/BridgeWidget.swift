import SwiftUI
import WidgetKit

@main
struct BridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        BridgeActivityWidget()
        BridgeSuggestWidget()
        BridgeBoardWidget()
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
                .boxWidgetContainer()
                .widgetURL(URL(string: "bridge-widget://status"))
        }
        .configurationDisplayName("Activity")
        .description("Agent's last line. Latest jobs.")
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
        case .accessoryInline: Text(entry.snapshot.rows.first?.title ?? entry.snapshot.headline.localizedForDisplay).lineLimit(1)
        default: SmallView(entry: entry)
        }
    }
}

extension WidgetSnapshot.Dot {
    var square: StatusSquare.State {
        switch self {
        case .running: .running
        case .done: .done
        case .failed: .failed
        case .stale: .stale
        }
    }
}

/// Full color: the filled square. Tinted (.accented) and lock screen (.vibrant): outlined, and
/// only running / failed take the tint — the one accentable view in either widget.
private struct Square: View {
    @Environment(\.widgetRenderingMode) private var mode
    let dot: WidgetSnapshot.Dot

    var body: some View {
        StatusSquare(state: dot.square, outlined: mode != .fullColor)
            .font(Theme.Role.meta)
            .widgetAccentable(dot == .running || dot == .failed)
    }
}

private func ago(_ date: Date) -> String {
    date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
}

private struct SmallView: View {
    let entry: BridgeEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text("白手套").boxLabel()
            Text(snapshot.headline.localizedForDisplay)
                .font(Theme.Role.widgetBody)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let row = snapshot.rows.first {
                HStack(spacing: Theme.Space.s8) {
                    Square(dot: snapshot.dot(for: row, now: entry.date))
                    Text(ago(snapshot.time(of: row)))
                        .font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
        }
    }
}

private struct MediumView: View {
    let entry: BridgeEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack {
                Text("Activity").boxLabel()
                Spacer()
                if let line = snapshot.lastHealth {
                    Text(line).font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            BoxRule()
            if snapshot.rows.isEmpty {
                Text(snapshot.headline.localizedForDisplay).font(Theme.Role.widgetBody)
            }
            ForEach(snapshot.rows.prefix(3)) { row in
                HStack(spacing: Theme.Space.s8) {
                    Square(dot: snapshot.dot(for: row, now: entry.date))
                    Text(row.title).font(Theme.Role.widgetBody).lineLimit(1)
                    Spacer(minLength: Theme.Space.s4)
                    Text(ago(snapshot.time(of: row)))
                        .font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
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
        VStack(alignment: .leading, spacing: Theme.Space.s0) {
            if let row = snapshot.rows.first {
                HStack(spacing: Theme.Space.s4) {
                    Square(dot: snapshot.dot(for: row, now: entry.date))
                    Text(row.status.rawValue.localizedForDisplay).font(Theme.Role.label).textCase(.uppercase).tracking(Theme.labelTracking)
                    Text(ago(snapshot.time(of: row))).font(Theme.Role.meta)
                }
                Text(row.title).font(Theme.Role.widgetBody.bold()).lineLimit(2)
            } else {
                Text(snapshot.headline.localizedForDisplay).font(Theme.Role.widgetBody.bold()).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Suggest · 推荐

struct SuggestEntry: TimelineEntry, Sendable {
    let date: Date
    let suggestions: Suggestions
}

/// The box's suggestions, saved to the App Group (the app resolves taps from that file);
/// on a failed fetch, the last ones saved.
struct SuggestProvider: TimelineProvider {
    static let refresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> SuggestEntry {
        SuggestEntry(date: Date(), suggestions: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SuggestEntry) -> Void) {
        let suggestions = context.isPreview ? .sample : (SharedStore.loadSuggestions() ?? .sample)
        completion(SuggestEntry(date: Date(), suggestions: suggestions))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SuggestEntry>) -> Void) {
        let done = Completion(call: completion)
        Task {
            let suggestions: Suggestions
            if let fresh = await SharedStore.fetchSuggestions() {
                try? SharedStore.save(fresh)
                suggestions = fresh
            } else {
                suggestions = SharedStore.loadSuggestions() ?? Suggestions(generatedAt: Date(), items: [])
            }
            let now = Date()
            done.call(Timeline(entries: [SuggestEntry(date: now, suggestions: suggestions)],
                               policy: .after(now.addingTimeInterval(Self.refresh))))
        }
    }
}

struct BridgeSuggestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BridgeSuggest", provider: SuggestProvider()) { entry in
            SuggestView(entry: entry)
                .boxWidgetContainer()
        }
        .configurationDisplayName("Suggest")
        .description("Four things to open now. Rules, not guesses.")
        .supportedFamilies([.systemMedium])
    }
}

private struct SuggestView: View {
    let entry: SuggestEntry

    var body: some View {
        let items = Array(entry.suggestions.items.prefix(Suggestions.slots))
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack {
                Text("Suggest").boxLabel()
                Spacer()
                Text(entry.suggestions.generatedAt, style: .time)
                    .font(Theme.Role.meta).monospacedDigit().foregroundStyle(Theme.dim)
            }
            BoxRule()
            if items.isEmpty {
                Text("Nothing to suggest.").font(Theme.Role.widgetBody).foregroundStyle(Theme.dim)
                Spacer(minLength: Theme.Space.s0)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s8) {
                    ForEach(items) { item in
                        if let url = SuggestRoute.url(for: item.id) {
                            Link(destination: url) { SuggestSlot(item: item) }
                        } else {
                            SuggestSlot(item: item)
                        }
                    }
                    ForEach(items.count..<Suggestions.slots, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct SuggestSlot: View {
    @Environment(\.widgetRenderingMode) private var mode
    let item: Suggestions.Item

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            glyph
            Text(item.title).font(Theme.Role.widgetBody.bold()).lineLimit(1)
            if let reason = item.shownReason {
                Text(reason).font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// An SF Symbol for what the slot does; an app keeps its catalog glyph (微, 支 …): there is
    /// no system symbol for a third-party app, and the glyph is the catalog's data, like a lane's
    /// colour. Sized by the text style, outlined, never filled: a filled block flattens into one
    /// lump of tint outside full colour.
    /// Every box is sized by a hidden full-width character, so the boxes match and scale with
    /// Dynamic Type without a fixed frame.
    @ViewBuilder private var glyph: some View {
        Text(verbatim: "微").hidden()
            .overlay {
                if let symbol = SuggestGlyph.symbol(for: item) {
                    Image(systemName: symbol)
                } else {
                    Text(item.glyph)
                }
            }
            .font(Theme.Role.subhead.bold())
            .foregroundStyle(Theme.text)
            .padding(Theme.Space.s8)
            .overlay(Rectangle().strokeBorder(mode == .fullColor ? Theme.line : Theme.dim, lineWidth: Theme.hairline))
    }
}

#Preview(as: .systemMedium) {
    BridgeSuggestWidget()
} timeline: {
    SuggestEntry(date: Date(), suggestions: .sample)
}

// Tinted Home Screen icons. Widget previews can't set the rendering mode, so these render the
// views directly with it overridden.
#Preview("Suggest · tinted") {
    SuggestView(entry: SuggestEntry(date: Date(), suggestions: .sample))
        .boxWidgetContainer()
        .environment(\.widgetRenderingMode, .accented)
        .padding()
        .frame(width: WidgetPreview.medium.width, height: WidgetPreview.medium.height)
}

#Preview("Activity · tinted") {
    MediumView(entry: BridgeEntry(date: Date(), snapshot: .sample))
        .boxWidgetContainer()
        .environment(\.widgetRenderingMode, .accented)
        .padding()
        .frame(width: WidgetPreview.medium.width, height: WidgetPreview.medium.height)
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
