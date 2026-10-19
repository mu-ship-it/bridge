import Foundation
import Security

/// What the widgets show, shared between the app and the widget extension through the App Group.
/// Small on purpose: the last few feed rows and one-line summaries, never a whole result.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Row: Codable, Sendable, Equatable, Identifiable {
        enum Status: String, Codable, Sendable { case queued, running, done, failed }

        let id: String
        let capability: String
        let note: String?
        let status: Status
        /// When the phone started it (rows written by the app); the box's feed does not say.
        var startedAt: Date?
        var finishedAt: Date?
        let summary: String

        /// The row's own words: the agent's note, else the summary, else the capability.
        var title: String {
            for text in [note, summary] {
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
            }
            return capability
        }
    }

    /// The colour of a row's status dot. Anything that last moved more than an hour ago is stale.
    enum Dot: String, Sendable { case running, done, failed, stale }

    var rows: [Row] = []
    var agentLine: String?
    var lastPoll: Date?
    var lastHealth: String?
    /// When this snapshot was made (by the app, or by the widget from the box's feed).
    var generatedAt: Date
    /// "app" or "box": who made it.
    var source: String = "app"

    static let rowLimit = 5
    static let staleAfter: TimeInterval = 3600

    /// The latest thing to say: the agent's last line, else the newest row.
    var headline: String {
        if let line = agentLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { return line }
        return rows.first?.title ?? "Nothing yet"
    }

    func time(of row: Row) -> Date { row.finishedAt ?? row.startedAt ?? generatedAt }

    func dot(for row: Row, now: Date = Date()) -> Dot {
        if now.timeIntervalSince(time(of: row)) > Self.staleAfter { return .stale }
        switch row.status {
        case .queued, .running: return .running
        case .done: return .done
        case .failed: return .failed
        }
    }

    // MARK: Encoding (ISO-8601 dates, so the file stays readable)

    static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: The box's GET /bridge/feed

    struct Feed: Decodable, Sendable {
        struct Job: Decodable, Sendable {
            let id: String
            let capability: String
            let note: String?
            let status: String
            let finishedAt: String?
            let summary: String?

            enum CodingKeys: String, CodingKey {
                case id, capability, note, status, summary
                case finishedAt = "finished_at"
            }
        }
        let jobs: [Job]
        let agentLine: String?

        enum CodingKeys: String, CodingKey {
            case jobs
            case agentLine = "agent_line"
        }
    }

    /// The box's view, keeping what only the phone knows (last poll, last health sync) from `local`.
    init(feed: Feed, local: WidgetSnapshot?, now: Date = Date()) {
        let iso = ISO8601DateFormatter()
        rows = feed.jobs.prefix(Self.rowLimit).map { job in
            Row(id: job.id, capability: job.capability, note: job.note,
                status: Row.Status(rawValue: job.status) ?? .running,
                startedAt: local?.rows.first { $0.id == job.id }?.startedAt,
                finishedAt: job.finishedAt.flatMap { iso.date(from: $0) },
                summary: job.summary ?? "")
        }
        agentLine = feed.agentLine
        lastPoll = local?.lastPoll
        lastHealth = local?.lastHealth
        generatedAt = now
        source = "box"
    }

    init(rows: [Row], agentLine: String?, lastPoll: Date?, lastHealth: String?, generatedAt: Date = Date()) {
        self.rows = Array(rows.prefix(Self.rowLimit))
        self.agentLine = agentLine
        self.lastPoll = lastPoll
        self.lastHealth = lastHealth
        self.generatedAt = generatedAt
    }

    static let sample = WidgetSnapshot(
        rows: [
            Row(id: "j_3", capability: "health.query", note: "Checking how you slept before suggesting a run",
                status: .running, startedAt: Date().addingTimeInterval(-40), summary: ""),
            Row(id: "j_2", capability: "device.info", note: "Battery check", status: .done,
                startedAt: Date().addingTimeInterval(-600), finishedAt: Date().addingTimeInterval(-598),
                summary: "battery 85% charging"),
            Row(id: "j_1", capability: "location.now", note: "Are you home yet?", status: .failed,
                startedAt: Date().addingTimeInterval(-1500), finishedAt: Date().addingTimeInterval(-1490),
                summary: "Location not requested yet"),
        ],
        agentLine: "Morning — you slept 7 h 20 min, a good night for a run.",
        lastPoll: Date().addingTimeInterval(-30), lastHealth: "Synced 4 metrics")
}

/// The App Group container and the shared Keychain group, both derived from the app's bundle id
/// (Info.plist keys filled in by project.yml).
enum SharedStore {
    private static func info(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else { return nil }
        return v
    }

    static var appGroup: String? { info("BridgeAppGroup") }
    static var keychainGroup: String? { info("BridgeKeychainGroup") }
    /// The app's bundle id — the Keychain service its items live under.
    static var appBundleID: String { info("BridgeAppBundleID") ?? Bundle.main.bundleIdentifier ?? "Bridge" }

    static var snapshotURL: URL? {
        guard let group = appGroup,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return dir.appending(path: "widget-snapshot.json")
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? WidgetSnapshot.decode(data)
    }

    static func save(_ snapshot: WidgetSnapshot) throws {
        guard let url = snapshotURL else { return }
        // Readable after first unlock: the widget refreshes on a locked phone.
        try snapshot.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Box URL, token and device id, read from the app's Keychain items through the shared access group.
    static func boxCredentials() -> (url: URL, token: String, device: String)? {
        func read(_ account: String) -> String? {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: appBundleID,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let group = keychainGroup { query[kSecAttrAccessGroup as String] = group }
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let raw = read("box_url"), let url = URL(string: raw),
              let token = read("token"), let device = read("device_id") else { return nil }
        return (url, token, device)
    }
}
