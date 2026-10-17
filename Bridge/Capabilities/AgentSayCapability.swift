import Foundation

/// Parsed `agent.say` params: `text` (required, max 2000 chars), `notify` (default false).
struct AgentSayParams: Sendable, Equatable {
    let text: String
    let notify: Bool

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let text = try Params.string(p, "text") else { throw CapabilityError.badParams("'text' is required") }
        guard text.count <= 2000 else { throw CapabilityError.badParams("'text' max 2000 chars") }
        self.text = text
        notify = try Params.bool(p, "notify") ?? false
    }
}

/// `agent.say` {text, notify?} → the agent narrates in the app's activity feed (the job's own row shows `text`),
/// and with `notify: true` also as a local notification. Result `{ok, notified, notify_error?}`.
struct AgentSayCapability: Capability {
    let name = "agent.say"

    func run(_ job: Job) async throws -> JSONValue {
        let p = try AgentSayParams(job.params)
        var out: [String: JSONValue] = ["ok": .bool(true), "notified": .bool(false)]
        if p.notify {
            let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Bridge"
            do {
                try await NotifyShowCapability.post(id: "bridge.\(job.id)", title: title, body: p.text, sound: true)
                out["notified"] = .bool(true)
            } catch let error as CapabilityError {
                out["notify_error"] = .string(error.code) // the feed entry still counts; don't fail the job
            } catch {
                out["notify_error"] = .string("failed")
            }
        }
        return .object(out)
    }
}
