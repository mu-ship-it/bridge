import Foundation

/// The Suggest · 推荐 widget's slots, from the box's GET /bridge/suggest. The widget keeps the
/// last good list in the App Group, so a failed fetch still shows something and the app can
/// resolve a tapped slot (`bridge://suggest/<id>`) to its target.
struct Suggestions: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Codable, Sendable { case app, capability, shortcut, url }

        let id: String
        let kind: Kind
        let title: String
        let glyph: String
        let reason: String
        /// A URL or scheme (app, url), a capability name, or a shortcut's name.
        let target: String
        /// Capability items only.
        var params: [String: JSONValue]?

        /// The reason worth showing under the title; nil for the generic fallback
        /// ("", "app", "usual" — older boxes still send "app").
        var shownReason: String? {
            let flat = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.genericReasons.contains(flat.lowercased()) ? nil : flat
        }

        static let genericReasons: Set<String> = ["", "app", "usual"]
    }

    var generatedAt: Date
    var items: [Item]

    static let slots = 4
    static let fetchTimeout: TimeInterval = 5

    enum CodingKeys: String, CodingKey {
        case items
        case generatedAt = "generated_at"
    }

    static func decode(_ data: Data) throws -> Suggestions {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Suggestions.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func item(id: String) -> Item? { items.first { $0.id == id } }

    static let sample = Suggestions(generatedAt: Date(), items: [
        Item(id: "cal.sample", kind: .url, title: "Standup", glyph: "日", reason: "in 25m", target: "calshow:0"),
        Item(id: "retry.sample", kind: .capability, title: "Retry location.now", glyph: "↻", reason: "failed 12m",
             target: "location.now", params: [:]),
        Item(id: "app.wechat", kind: .app, title: "WeChat", glyph: "微", reason: "usual 08h", target: "weixin://"),
        Item(id: "app.boringbox", kind: .app, title: "Boring Box", glyph: "B", reason: "",
             target: "https://boringbox.dev/box/"),
    ])
}

// MARK: Glyph

/// Which SF Symbol a Suggest slot shows. nil = an app: show the catalog's own glyph.
enum SuggestGlyph {
    static func symbol(for item: Suggestions.Item) -> String? {
        switch item.kind {
        case .app: nil
        case .capability: item.id.hasPrefix("retry.") ? "arrow.clockwise" : "bolt"
        case .shortcut: "square.2.layers.3d"
        case .url: item.id.hasPrefix("cal.") ? "calendar" : item.id.hasPrefix("lane.") ? "rectangle.stack" : "link"
        }
    }
}

// MARK: Widget URL → action

/// What a tap on a Suggest slot does. Pure, so routing is unit-tested without UIKit.
enum SuggestRoute: Equatable {
    static let scheme = "bridge"
    static let host = "suggest"

    case open(URL)
    case capability(String, [String: JSONValue])
    case shortcut(String)

    static func url(for id: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://\(host)/\(escaped)")
    }

    /// `bridge://suggest/<id>` → `<id>`; anything else → nil.
    static func itemID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host() == host else { return nil }
        let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }

    static func action(for item: Suggestions.Item) -> SuggestRoute? {
        switch item.kind {
        case .app, .url:
            guard let url = URL(string: item.target), url.scheme != nil else { return nil }
            return .open(url)
        case .capability:
            return item.target.isEmpty ? nil : .capability(item.target, item.params ?? [:])
        case .shortcut:
            return item.target.isEmpty ? nil : .shortcut(item.target)
        }
    }
}

extension SharedStore {
    static var suggestionsURL: URL? {
        guard let group = appGroup,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return dir.appending(path: "suggestions.json")
    }

    static func loadSuggestions() -> Suggestions? {
        guard let url = suggestionsURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? Suggestions.decode(data)
    }

    static func save(_ suggestions: Suggestions) throws {
        guard let url = suggestionsURL else { return }
        try suggestions.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// GET /bridge/suggest with the shared credentials, in the phone's own time zone.
    static func fetchSuggestions() async -> Suggestions? {
        guard let box = boxCredentials(),
              var components = URLComponents(url: box.url.appending(path: "bridge/suggest"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [.init(name: "device", value: box.device),
                                 .init(name: "tz", value: TimeZone.current.identifier)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Suggestions.fetchTimeout)
        request.setValue("Bearer \(box.token)", forHTTPHeaderField: "Authorization")
        request.setValue(box.device, forHTTPHeaderField: "X-Bridge-Device")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? Suggestions.decode(data)
    }
}
