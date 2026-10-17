import Foundation
import UIKit

/// `clipboard.get`: current pasteboard text. No params.
/// Result: `{text, has_image, changed_at?}`. `changed_at` is only known when Bridge itself set the content.
/// iOS may show its "Allow Paste" prompt when the app is in the foreground, and returns nothing in the background.
struct ClipboardGetCapability: Capability {
    let name = "clipboard.get"

    func run(_ job: Job) async throws -> JSONValue {
        await MainActor.run {
            let board = UIPasteboard.general
            var o: [String: JSONValue] = [
                "text": board.hasStrings ? (board.string.map(JSONValue.string) ?? .null) : .null,
                "has_image": .bool(board.hasImages),
            ]
            if let set = ClipboardStamp.load(), set.changeCount == board.changeCount {
                o["changed_at"] = .string(ISO.string(set.date))
            }
            return .object(o)
        }
    }
}

/// Parsed `clipboard.set` params: `text` (required, may be empty only if explicitly a string).
struct ClipboardSetParams: Sendable, Equatable {
    let text: String

    init(_ params: [String: JSONValue]?) throws {
        guard case .string(let s)? = params?["text"] else { throw CapabilityError.badParams("'text' (string) is required") }
        guard s.utf8.count <= 1_000_000 else { throw CapabilityError.badParams("'text' is too long (max 1 MB)") }
        text = s
    }
}

/// `clipboard.set` {text} → `{ok: true}`.
struct ClipboardSetCapability: Capability {
    let name = "clipboard.set"

    func run(_ job: Job) async throws -> JSONValue {
        let p = try ClipboardSetParams(job.params)
        await MainActor.run {
            let board = UIPasteboard.general
            board.string = p.text
            ClipboardStamp.save(changeCount: board.changeCount, date: Date())
        }
        return .object(["ok": .bool(true)])
    }
}

/// Remembers when Bridge last wrote the pasteboard, keyed by `changeCount`.
enum ClipboardStamp {
    private static let countKey = "clipboard.set.changeCount"
    private static let dateKey = "clipboard.set.date"

    static func save(changeCount: Int, date: Date) {
        UserDefaults.standard.set(changeCount, forKey: countKey)
        UserDefaults.standard.set(date, forKey: dateKey)
    }

    static func load() -> (changeCount: Int, date: Date)? {
        guard let date = UserDefaults.standard.object(forKey: dateKey) as? Date else { return nil }
        return (UserDefaults.standard.integer(forKey: countKey), date)
    }
}
