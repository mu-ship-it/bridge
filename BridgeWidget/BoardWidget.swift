import SwiftUI
import WidgetKit

// MARK: Board

struct BoardEntry: TimelineEntry, Sendable {
    let date: Date
    let name: String
    let snapshot: BoardSnapshot?
}

/// The box's board, saved to the App Group (the app compares its own fetches against it);
/// on a failed fetch, the last one saved — which then shows its age and goes stale.
struct BoardProvider: AppIntentTimelineProvider {
    static let refresh: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: Date(), name: BoardName.fallback, snapshot: Self.sample)
    }

    func snapshot(for configuration: BoardIntent, in context: Context) async -> BoardEntry {
        let name = BoardName.normalized(configuration.name)
        if context.isPreview { return BoardEntry(date: Date(), name: name, snapshot: Self.sample) }
        return BoardEntry(date: Date(), name: name, snapshot: SharedStore.loadBoard(name) ?? Self.sample)
    }

    func timeline(for configuration: BoardIntent, in context: Context) async -> Timeline<BoardEntry> {
        let name = BoardName.normalized(configuration.name)
        let snapshot: BoardSnapshot?
        if let fresh = await SharedStore.fetchBoard(name) {
            try? SharedStore.save(fresh)
            snapshot = fresh
        } else {
            snapshot = SharedStore.loadBoard(name)
        }
        let now = Date()
        var entries = [BoardEntry(date: now, name: name, snapshot: snapshot)]
        // A second entry the moment it turns stale, so the badge shows without a reload.
        if let snapshot, !snapshot.isStale(at: now), snapshot.staleAt < now.addingTimeInterval(Self.refresh) {
            entries.append(BoardEntry(date: snapshot.staleAt.addingTimeInterval(1), name: name, snapshot: snapshot))
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refresh)))
    }

    static var sample: BoardSnapshot {
        BoardSnapshot(name: BoardName.fallback, board: .sample, receivedAt: Date().addingTimeInterval(-20), fetchedAt: Date())
    }
}

struct BridgeBoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BoardWidgetKind.kind, intent: BoardIntent.self, provider: BoardProvider()) { entry in
            BoardWidgetView(name: entry.name, snapshot: entry.snapshot, date: entry.date)
                .boxWidgetContainer()
        }
        .configurationDisplayName("Board · 看板")
        .description("A board from your box: labelled bars, live.")
        .supportedFamilies(Self.families)
    }

    #if os(macOS)
    static let families: [WidgetFamily] = [.systemMedium, .systemLarge, .systemExtraLarge]
    #else
    static let families: [WidgetFamily] = [.systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
    #endif
}

#Preview(as: .systemMedium) {
    BridgeBoardWidget()
} timeline: {
    BoardEntry(date: Date(), name: "muster", snapshot: BoardProvider.sample)
}

#Preview(as: .systemLarge) {
    BridgeBoardWidget()
} timeline: {
    BoardEntry(date: Date(), name: "muster", snapshot: BoardProvider.sample)
}

#Preview("Board · tinted") {
    BoardWidgetView(name: "muster", snapshot: BoardProvider.sample, date: Date())
        .boxWidgetContainer()
        .environment(\.widgetRenderingMode, .accented)
        .padding()
        .frame(width: WidgetPreview.medium.width, height: WidgetPreview.medium.height)
}
