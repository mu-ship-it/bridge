import UIKit

/// Parsed `share` params: at least one of `text`, `url`, `file` (a name in the 白手套 Documents
/// folder, see `files.write`); `timeout` (5–110 s, default 90).
struct ShareParams: Sendable, Equatable {
    let text: String?
    let url: URL?
    let file: String?
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        text = try Params.string(p, "text")
        if let raw = try Params.string(p, "url") {
            guard let u = URL(string: raw), u.scheme != nil else { throw CapabilityError.badParams("'url' must be an absolute URL") }
            url = u
        } else {
            url = nil
        }
        file = p["file"] == nil ? nil : try FileStore.validName(["name": p["file"]!])
        guard text != nil || url != nil || file != nil else {
            throw CapabilityError.badParams("Give at least one of 'text', 'url' or 'file'")
        }
        timeout = try Presenter.timeout(p)
    }
}

/// `share` → presents the share sheet; Mu picks where it goes. Result: `{completed: true, activity}`
/// (`activity` is iOS' id for the chosen target, e.g. `com.apple.UIKit.activity.Message`).
/// Mu closing the sheet is `ok:false`, code `cancelled`.
struct ShareCapability: Capability {
    let name = "share"
    var store = FileStore.documents

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ShareParams(job.params)
        var fileURL: URL?
        if let file = q.file {
            fileURL = store.url(file)
            guard FileManager.default.fileExists(atPath: fileURL!.path) else {
                throw CapabilityError(code: "not_found", message: "No file named '\(file)'")
            }
        }
        let activity: String = try await Presenter.present(timeout: q.timeout) { [fileURL] session in
            var items: [Any] = []
            if let text = q.text { items.append(text) }
            if let url = q.url { items.append(url) }
            if let fileURL { items.append(fileURL) }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.completionWithItemsHandler = { type, completed, _, error in
                if let error {
                    session.fail(CapabilityError(code: "failed", message: error.localizedDescription))
                } else if completed {
                    session.succeed(type?.rawValue ?? "unknown")
                } else {
                    session.fail(CapabilityError.cancelled)
                }
            }
            return sheet
        }
        return .object(["completed": .bool(true), "activity": .string(activity)])
    }
}
