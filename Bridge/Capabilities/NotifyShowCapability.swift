import Foundation
import UserNotifications

/// Parsed `notify.show` params: `title` (required), `body` (optional), `sound` (default true).
struct NotifyShowParams: Sendable, Equatable {
    let title: String
    let body: String
    let sound: Bool

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        let title = try Params.string(p, "title")
        let body = try Params.string(p, "body")
        guard title != nil || body != nil else { throw CapabilityError.badParams("'title' or 'body' is required") }
        self.title = title ?? ""
        self.body = body ?? ""
        guard self.title.count <= 200, self.body.count <= 4000 else {
            throw CapabilityError.badParams("'title' max 200 chars, 'body' max 4000")
        }
        sound = try Params.bool(p, "sound") ?? true
    }
}

/// `notify.show` {title, body, sound?} → shows a local notification right away.
/// Asks for notification permission the first time (the prompt only appears while the app is open).
struct NotifyShowCapability: Capability {
    let name = "notify.show"

    func run(_ job: Job) async throws -> JSONValue {
        let p = try NotifyShowParams(job.params)
        let id = "bridge.\(job.id)"
        try await Self.post(id: id, title: p.title, body: p.body, sound: p.sound)
        return .object(["ok": .bool(true), "id": .string(id)])
    }

    /// Shows a local notification now, asking for permission first if it was never asked.
    static func post(id: String, title: String, body: String, sound: Bool) async throws {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .denied: throw CapabilityError.permissionDenied("Notifications")
        case .notDetermined:
            guard (try? await Self.requestAuthorization()) == true else { throw CapabilityError.permissionMissing("Notifications") }
        default: break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
