import AppIntents
import WidgetKit

/// The board widget's one setting: which board to show (`GET /bridge/board/<name>`).
/// Shared with the app, which reads the configured names to know which boards to poll.
struct BoardIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Board"
    static let description = IntentDescription("Which board from your box to show.")

    @Parameter(title: "Board name", default: "muster")
    var name: String

    init() {}

    init(name: String) {
        self.name = name
    }
}

enum BoardWidgetKind {
    static let kind = "BridgeBoard"

    /// The board names of every board widget on screen, deduplicated.
    static func configuredNames() async -> [String] {
        guard let configs = try? await WidgetCenter.shared.currentConfigurations() else { return [] }
        let names = configs.filter { $0.kind == kind }
            .map { BoardName.normalized($0.widgetConfigurationIntent(of: BoardIntent.self)?.name) }
        return Array(Set(names)).sorted()
    }
}
