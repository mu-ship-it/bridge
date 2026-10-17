import UIKit

/// Hands a URL to iOS, which opens the app that owns its scheme. Shared by `open.url`,
/// `shortcuts.run`, `settings.open` and `call`. iOS opens URLs only for the app on screen.
enum URLOpener {
    @MainActor
    static func open(_ url: URL) async throws -> Bool {
        try Presenter.requireForeground()
        return await UIApplication.shared.open(url)
    }

    /// Query encoding that leaves nothing for the receiving app to misread (`+`, `&`, `=` included).
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

/// `open.url` {url} → opens any URL scheme iOS can route (https, maps, tel, weixin, …): `{opened}`.
/// `opened: false` means no installed app handles that scheme. 白手套 then leaves the screen.
struct OpenURLParams: Sendable, Equatable {
    let url: URL

    init(_ params: [String: JSONValue]?) throws {
        guard let raw = try Params.string(params ?? [:], "url") else { throw CapabilityError.badParams("'url' (string) is required") }
        guard raw.count <= 8000, let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
            throw CapabilityError.badParams("'url' must be an absolute URL with a scheme, e.g. https://… or maps://…")
        }
        self.url = url
    }
}

struct OpenURLCapability: Capability {
    let name = "open.url"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try OpenURLParams(job.params)
        return .object(["opened": .bool(try await URLOpener.open(q.url))])
    }
}

/// `shortcuts.run` {name, input?} → opens the Shortcuts app running that shortcut: `{opened}`.
/// `input` (string, or any JSON — sent as its JSON text) is passed as the shortcut's text input.
/// The shortcut's output does not come back here; a shortcut that should report must call the box itself.
struct ShortcutsRunParams: Sendable, Equatable {
    let name: String
    let input: String?

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let name = try Params.string(p, "name") else { throw CapabilityError.badParams("'name' (the shortcut's exact name) is required") }
        self.name = name
        switch p["input"] {
        case nil, .null?: input = nil
        case .string(let s)?: input = s
        case let other?:
            let data = try JSONEncoder().encode(other)
            input = String(decoding: data, as: UTF8.self)
        }
    }

    var url: URL {
        var items = [("name", name)]
        if let input { items += [("input", "text"), ("text", input)] }
        return URL(string: "shortcuts://run-shortcut?" + URLOpener.query(items))!
    }
}

struct ShortcutsRunCapability: Capability {
    let name = "shortcuts.run"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ShortcutsRunParams(job.params)
        return .object(["opened": .bool(try await URLOpener.open(q.url))])
    }
}

/// `settings.open` {section} → opens that page of the Settings app: `{opened, section}`.
/// `app` (白手套's own page) and `app_notifications` use Apple's public URLs. The system pages use
/// Settings' `App-prefs:` links, which Apple does not document: on some iOS versions they land on
/// the top of Settings instead of the exact page.
struct SettingsOpenParams: Sendable, Equatable {
    static let sections: [String: String] = [
        "app": UIApplication.openSettingsURLString,
        "app_notifications": UIApplication.openNotificationSettingsURLString,
        "wifi": "App-prefs:WIFI",
        "bluetooth": "App-prefs:Bluetooth",
        "notifications": "App-prefs:NOTIFICATIONS_ID",
        "privacy": "App-prefs:Privacy",
        "battery": "App-prefs:BATTERY_USAGE",
        "display": "App-prefs:DISPLAY",
        "focus": "App-prefs:DO_NOT_DISTURB",
        "cellular": "App-prefs:MOBILE_DATA_SETTINGS_ID",
        "general": "App-prefs:General",
    ]

    let section: String
    var url: URL { URL(string: Self.sections[section]!)! }

    init(_ params: [String: JSONValue]?) throws {
        section = try Params.choice(params ?? [:], "section", Self.sections.keys.sorted()) ?? "app"
    }
}

struct SettingsOpenCapability: Capability {
    let name = "settings.open"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try SettingsOpenParams(job.params)
        return .object(["opened": .bool(try await URLOpener.open(q.url)), "section": .string(q.section)])
    }
}
