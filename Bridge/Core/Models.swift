import Foundation

/// A unit of work handed to the phone by the box. See docs/API.md.
struct Job: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let capability: String
    var params: [String: JSONValue]?
    var createdAt: String?
    /// Optional one-line, plain-words reason from the agent, shown in the activity feed.
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id, capability, params, note
        case createdAt = "created_at"
    }
}

struct JobError: Codable, Sendable, Equatable {
    let code: String
    let message: String
}

struct JobResult: Codable, Sendable, Equatable {
    let jobId: String
    let ok: Bool
    var result: JSONValue?
    var error: JobError?
    let startedAt: String
    let finishedAt: String

    enum CodingKeys: String, CodingKey {
        case ok, result, error
        case jobId = "job_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct JobsResponse: Codable, Sendable {
    let jobs: [Job]
    var pollAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case jobs
        case pollAfterSeconds = "poll_after_seconds"
    }
}

struct ResultsRequest: Codable, Sendable {
    let device: String
    let results: [JobResult]
}

/// Something the device reports on its own (`POST /bridge/events`): a duty heartbeat, a speech
/// segment. Like a job, it says in plain words what it is.
struct DeviceEvent: Codable, Sendable, Equatable {
    var type: String
    var ts: String
    var payload: JSONValue?
    var note: String
}

struct EventsRequest: Codable, Sendable {
    let device: String
    let events: [DeviceEvent]
}

struct DeviceRegistration: Codable, Sendable {
    let device: String
    let apnsToken: String
    let apnsEnvironment: String
    let appVersion: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case device, capabilities
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
        case appVersion = "app_version"
    }
}

enum AppInfo {
    /// Used for the Keychain service, log subsystem and BG task identifiers, so forks only change the bundle id.
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "Bridge" }

    /// Prefill for the Settings server URL, from `BRIDGE_DEFAULT_SERVER_URL` (Config/Bridge.xcconfig, overridable locally).
    static var defaultServerURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "BridgeDefaultServerURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

enum ISO {
    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Accepts full ISO-8601 (with or without fractional seconds) or a bare `yyyy-MM-dd`.
    static func date(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f.date(from: raw)
    }
}
