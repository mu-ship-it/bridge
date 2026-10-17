import Foundation

/// One row of the Status screen's activity feed: what the agent asked the phone to do, and how it went.
struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case running, done, failed }

    let id: String          // job id
    let time: Date
    let capability: String
    let note: String?
    var status: Status
    var summary: String
    /// The full result (or error) as pretty JSON, for the row's Copy button. Kept in memory only,
    /// never persisted: it can hold contact details or file contents. Rows from before a relaunch copy `summary`.
    var detail: String? = nil

    enum CodingKeys: String, CodingKey { case id, time, capability, note, status, summary }

    /// What Copy puts on the pasteboard.
    var copyText: String { detail ?? summary }
}

/// The feed's filter chips.
enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all, failed, running
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func apply(_ entries: [ActivityEntry]) -> [ActivityEntry] {
        switch self {
        case .all: entries
        case .failed: entries.filter { $0.status == .failed }
        case .running: entries.filter { $0.status == .running }
        }
    }
}

extension Job {
    /// The agent's one-line reason for this job: top-level `note`, else `params.note`
    /// (the reference server forwards params untouched but not extra top-level fields).
    var displayNote: String? {
        let raw = note ?? params?["note"]?.stringValue
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(300))
    }
}

/// One-line, human-readable result summaries for the feed. Pure, so it is unit-testable.
enum ActivitySummary {
    static func summarize(_ job: Job, _ result: JobResult) -> String {
        guard result.ok else {
            let code = result.error?.code ?? "error"
            let message = result.error?.message ?? ""
            return clip(message.isEmpty ? code : "\(code): \(message)")
        }
        let r = result.result ?? .null
        switch job.capability {
        case "agent.say":
            return clip(job.params?["text"]?.stringValue ?? "")
        case "location.now":
            guard let lat = r["lat"]?.doubleValue, let lon = r["lon"]?.doubleValue else { return "ok" }
            let acc = r["horizontal_accuracy_m"]?.doubleValue.map { " ±\(Int($0)) m" } ?? ""
            return String(format: "%.4f, %.4f", lat, lon) + acc
        case "device.info":
            let battery = r["battery_level"]?.doubleValue.map { "battery \(Int(($0 * 100).rounded()))%" } ?? "battery unknown"
            return "\(battery), \(r["battery_state"]?.stringValue ?? "")"
        case "motion.today":
            return "\(r["steps"]?.stringValue ?? "?") steps"
        case "clipboard.get":
            if let text = r["text"], case .string(let s) = text { return "text, \(s.count) chars" }
            return r["has_image"] == .bool(true) ? "image, no text" : "empty"
        case "notify.show":
            return "shown: \(clip(job.params?["title"]?.stringValue ?? job.params?["body"]?.stringValue ?? ""))"
        case "reminders.add":
            return "added: \(clip(r["title"]?.stringValue ?? ""))"
        case "camera.capture":
            return "photo \(r["width"]?.stringValue ?? "?")×\(r["height"]?.stringValue ?? "?")"
        case "mic.record":
            if let t = r["transcript"]?.stringValue { return clip("“\(t)”") }
            return "\(r["seconds"]?.stringValue ?? "?") s recorded"
        case "speak":
            return "said: \(clip(job.params?["text"]?.stringValue ?? ""))"
        case "open.url", "shortcuts.run", "settings.open":
            let target = job.params?["url"]?.stringValue ?? job.params?["name"]?.stringValue ?? job.params?["section"]?.stringValue ?? ""
            return (r["opened"] == .bool(true) ? "opened " : "could not open ") + clip(target, 80)
        case "compose.sms", "compose.mail", "call":
            return "sheet shown" + (r["user_action"]?.stringValue.map { " · \($0)" } ?? "")
        case "files.write":
            return "wrote \(r["name"]?.stringValue ?? "") (\(r["size"]?.stringValue ?? "?") bytes)"
        case "barcode.scan":
            return clip("\(r["symbology"]?.stringValue ?? ""): \(r["payload"]?.stringValue ?? "")")
        case "wifi.info":
            return r["connected"] == .bool(true) ? "on \(r["ssid"]?.stringValue ?? "?")" : "not on Wi-Fi"
        case "nfc.read":
            return "\(r["records"]?.arrayValue?.count ?? 0) record(s)"
        default:
            if let count = r["count"]?.stringValue { return "\(count) item(s)" }
            return "ok"
        }
    }

    /// Pretty JSON of the whole result for copying. Long base64 strings (photos, audio, files) become
    /// a size note so a copy stays readable; the text is capped at 64 000 characters.
    static func detail(_ result: JobResult) -> String {
        let value: JSONValue = result.ok
            ? (result.result ?? .null)
            : .object(["error": .object(["code": .string(result.error?.code ?? "error"), "message": .string(result.error?.message ?? "")])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(elideBlobs(value)) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 64_000 ? String(text.prefix(64_000)) + "\n…" : text
    }

    static func elideBlobs(_ value: JSONValue, key: String = "") -> JSONValue {
        switch value {
        case .string(let s) where s.count > 512 && (key.hasSuffix("base64") || key == "base64"):
            return .string("<\(key): \(s.count * 3 / 4 / 1024) KB, left out of the copy>")
        case .object(let o):
            return .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, elideBlobs($0.value, key: $0.key)) }))
        case .array(let a):
            return .array(a.map { elideBlobs($0, key: key) })
        default:
            return value
        }
    }

    static func clip(_ s: String, _ max: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }
}
