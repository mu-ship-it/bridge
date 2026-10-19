import AppIntents
import UIKit

// App Intents: Mu's own Shortcuts can call 白手套 directly, without the box. Each one runs a
// capability through the same dispatcher as a box job, and shows up in the Status activity feed
// with the note "From Shortcuts". Every intent opens the app first: 白手套 runs in the foreground.

/// Runs one capability for an intent, in the foreground and in the activity feed.
@MainActor
enum IntentRunner {
    static func run(_ capability: String, _ params: [String: JSONValue], note: String = "From Shortcuts") async throws -> JSONValue {
        // openAppWhenRun brings the app forward; give the scene a moment to become active.
        for _ in 0..<20 where !Presenter.isForeground { try await Task.sleep(for: .milliseconds(100)) }
        let job = Job(id: "shortcut-" + UUID().uuidString.prefix(8).lowercased(), capability: capability,
                      params: params, note: note)
        AppStatus.shared.jobStarted(job)
        let result = await BridgeRuntime.shared.dispatcher.dispatch(job)
        AppStatus.shared.jobFinished(job, result)
        guard result.ok else {
            throw IntentFailure(code: result.error?.code ?? "failed", message: result.error?.message ?? "")
        }
        return result.result ?? .null
    }
}

/// How a failed capability reads in the Shortcuts app.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let code: String
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(code): \(message)" }
}

struct SpeakIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Text"
    static let description = IntentDescription("Reads text aloud with 白手套 and finishes when it is done.")
    static let openAppWhenRun = true

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Rate", description: "0 slowest, 0.5 normal, 1 fastest", inclusiveRange: (0, 1)) var rate: Double?
    @Parameter(title: "Voice", description: "A language like zh-CN, or a voice identifier") var voice: String?

    static var parameterSummary: some ParameterSummary { Summary("Speak \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let rate { params["rate"] = .number(rate) }
        if let voice { params["voice"] = .string(voice) }
        _ = try await IntentRunner.run("speak", params)
        return .result()
    }
}

struct OpenURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL with 白手套"
    static let description = IntentDescription("Opens any link or app URL scheme (maps:, weixin:, https:) the way the agent's open.url does.")
    static let openAppWhenRun = true

    @Parameter(title: "URL") var url: URL

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$url)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let r = try await IntentRunner.run("open.url", ["url": .string(url.absoluteString)])
        return .result(value: r["opened"] == .bool(true))
    }
}

struct NotifyShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show 白手套 Notification"
    static let description = IntentDescription("Shows a local notification from 白手套.")
    static let openAppWhenRun = true

    @Parameter(title: "Title") var title: String
    @Parameter(title: "Body") var body: String?

    static var parameterSummary: some ParameterSummary { Summary("Notify \(\.$title)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        var params: [String: JSONValue] = ["title": .string(title)]
        if let body { params["body"] = .string(body) }
        _ = try await IntentRunner.run("notify.show", params)
        return .result()
    }
}

struct AgentSayIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to 白手套 Activity"
    static let description = IntentDescription("Writes a line into 白手套's activity feed, optionally as a notification too.")
    static let openAppWhenRun = true

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Also notify", default: false) var notify: Bool

    static var parameterSummary: some ParameterSummary { Summary("Say \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentRunner.run("agent.say", ["text": .string(text), "notify": .bool(notify)])
        return .result()
    }
}

/// Any capability by name, params as JSON text. Returns the result as JSON text, so a Shortcut
/// can use it ("Get Dictionary from Input"). This is the way results reach a Shortcut.
struct RunCapabilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Run 白手套 Capability"
    static let description = IntentDescription("Runs any 白手套 capability (camera.capture, home.set, files.read, …) and returns its result as JSON text.")
    static let openAppWhenRun = true

    @Parameter(title: "Capability", description: "e.g. device.info, home.list, files.read") var name: String
    @Parameter(title: "Params (JSON)", description: "A JSON object, e.g. {\"name\": \"notes.txt\"}") var params: String?

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$name) with \(\.$params)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let parsed = try Self.parse(params)
        let result = try await IntentRunner.run(name.trimmingCharacters(in: .whitespaces), parsed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .result(value: String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    static func parse(_ text: String?) throws -> [String: JSONValue] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw IntentFailure(code: "bad_params", message: "Params must be a JSON object, like {\"name\": \"notes.txt\"}")
        }
        return o
    }
}

/// Puts the intents in the Shortcuts app (and Siri / Spotlight) with no import step.
struct BridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunCapabilityIntent(), phrases: ["Run a capability in \(.applicationName)"],
                    shortTitle: "Run Capability", systemImageName: "bolt.horizontal")
        AppShortcut(intent: SpeakIntent(), phrases: ["Speak with \(.applicationName)"],
                    shortTitle: "Speak", systemImageName: "speaker.wave.2")
        AppShortcut(intent: OpenURLIntent(), phrases: ["Open a link with \(.applicationName)"],
                    shortTitle: "Open URL", systemImageName: "link")
        AppShortcut(intent: NotifyShowIntent(), phrases: ["Notify with \(.applicationName)"],
                    shortTitle: "Notify", systemImageName: "bell")
        AppShortcut(intent: AgentSayIntent(), phrases: ["Add to \(.applicationName) activity"],
                    shortTitle: "Add to Activity", systemImageName: "text.bubble")
    }
}
