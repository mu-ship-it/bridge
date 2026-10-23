import Foundation
import WidgetKit

/// While a window is on screen: every 30 s, fetch each board a board widget shows and reload
/// the board widgets only when what they show would change (see BoardSnapshot.needsReload).
/// No board widget on screen → no fetches.
struct BoardWatcher {
    static let interval: Duration = .seconds(30)

    var names: @Sendable () async -> [String] = { await BoardWidgetKind.configuredNames() }
    var fetch: @Sendable (String) async -> BoardSnapshot? = { await SharedStore.fetchBoard($0) }
    var shown: @Sendable (String) -> BoardSnapshot? = { SharedStore.loadBoard($0) }
    var reload: @Sendable () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: BoardWidgetKind.kind) }

    func run() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// One round. Returns whether it reloaded.
    @discardableResult
    func check(now: Date = Date()) async -> Bool {
        var changed = false
        for name in await names() {
            guard let fresh = await fetch(name) else { continue }
            if BoardSnapshot.needsReload(shown: shown(name), fresh: fresh, now: now) { changed = true }
        }
        if changed { reload() }
        return changed
    }
}
