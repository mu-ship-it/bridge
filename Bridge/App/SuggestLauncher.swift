import UIKit

/// Carries out a tap on the Suggest widget. The widget saved the list it showed to the App Group,
/// so the id resolves to the same target the user saw. The tap is logged to the box first (best
/// effort, never blocking the open), then the target opens: an app or URL through UIApplication,
/// a capability through the dispatcher, a shortcut through shortcuts.run.
@MainActor
enum SuggestLauncher {
    static let note = "From Suggest"

    static func launch(id: String) async {
        guard let item = SharedStore.loadSuggestions()?.item(id: id),
              let route = SuggestRoute.action(for: item) else { return }
        if let config = ConfigStore.load() {
            Task.detached { try? await BoxClient(config: config).postSuggestTap(id: id) }
        }
        switch route {
        case .open(let url):
            await UIApplication.shared.open(url)
        case .capability(let name, let params):
            _ = try? await IntentRunner.run(name, params, note: note)
        case .shortcut(let name):
            _ = try? await IntentRunner.run("shortcuts.run", ["name": .string(name)], note: note)
        }
    }
}
