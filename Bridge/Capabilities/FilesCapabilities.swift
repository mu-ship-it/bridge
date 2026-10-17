import Foundation

/// The app's Documents folder, which the Files app shows as "On My iPhone › 白手套"
/// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace). Flat: names only, no sub-folders.
struct FileStore: Sendable {
    static let maxBytes = 10_000_000
    let root: URL

    static let documents = FileStore(root: URL.documentsDirectory)

    /// A plain file name: no path separators, not hidden, ≤ 255 bytes.
    static func validName(_ params: [String: JSONValue]) throws -> String {
        guard let name = try Params.string(params, "name") else { throw CapabilityError.badParams("'name' (string) is required") }
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), !name.contains(":"),
              name.utf8.count <= 255, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CapabilityError.badParams("'name' must be a plain file name like notes.txt (no folders, not starting with '.')")
        }
        return name
    }

    func url(_ name: String) -> URL { root.appending(path: name, directoryHint: .notDirectory) }

    func write(_ name: String, _ data: Data, append: Bool) throws -> Int {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = url(name)
        if append, let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            guard Int(end) + data.count <= Self.maxBytes else { throw CapabilityError.badParams("File would exceed 10 MB") }
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? data.count
    }

    func read(_ name: String) throws -> Data {
        let target = url(name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw CapabilityError(code: "not_found", message: "No file named '\(name)'")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        guard size <= Self.maxBytes else { throw CapabilityError.badParams("'\(name)' is larger than 10 MB") }
        return try Data(contentsOf: target)
    }

    func list() throws -> [JSONValue] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return try items.compactMap { item -> (String, JSONValue)? in
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { return nil }
            return (item.lastPathComponent, .object([
                "name": .string(item.lastPathComponent),
                "size": .number(Double(values.fileSize ?? 0)),
                "modified": values.contentModificationDate.map { .string(ISO.string($0)) } ?? .null,
            ]))
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        .map(\.1)
    }
}

/// Parsed `files.write` params: `name`, exactly one of `text` / `base64`, `append` (default false).
struct FilesWriteParams: Sendable, Equatable {
    let name: String
    let data: Data
    let append: Bool

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        name = try FileStore.validName(p)
        append = try Params.bool(p, "append") ?? false
        switch (p["text"], p["base64"]) {
        case (.string(let text)?, nil), (.string(let text)?, .null?):
            data = Data(text.utf8)
        case (nil, .string(let b64)?), (.null?, .string(let b64)?):
            guard let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw CapabilityError.badParams("'base64' is not valid base64")
            }
            data = decoded
        default:
            throw CapabilityError.badParams("Give exactly one of 'text' or 'base64' (string)")
        }
        guard data.count <= FileStore.maxBytes else { throw CapabilityError.badParams("Content is larger than 10 MB") }
    }
}

/// `files.write` {name, text|base64, append?} → `{name, size}`.
struct FilesWriteCapability: Capability {
    let name = "files.write"
    var store = FileStore.documents

    func run(_ job: Job) async throws -> JSONValue {
        let q = try FilesWriteParams(job.params)
        let size = try store.write(q.name, q.data, append: q.append)
        return .object(["name": .string(q.name), "size": .number(Double(size))])
    }
}

/// `files.read` {name, as?} → `{name, size, text}` for UTF-8 files, else `{name, size, base64}`.
/// `as: "base64"` always returns base64.
struct FilesReadCapability: Capability {
    let name = "files.read"
    var store = FileStore.documents

    func run(_ job: Job) async throws -> JSONValue {
        let p = job.params ?? [:]
        let fileName = try FileStore.validName(p)
        let forceBase64 = try Params.choice(p, "as", ["text", "base64"]) == "base64"
        let data = try store.read(fileName)
        var o: [String: JSONValue] = ["name": .string(fileName), "size": .number(Double(data.count))]
        if !forceBase64, let text = String(data: data, encoding: .utf8) {
            o["text"] = .string(text)
        } else {
            o["base64"] = .string(data.base64EncodedString())
        }
        return .object(o)
    }
}

/// `files.list` → `{count, files: [{name, size, modified}]}`, sorted by name.
struct FilesListCapability: Capability {
    let name = "files.list"
    var store = FileStore.documents

    func run(_ job: Job) async throws -> JSONValue {
        let files = try store.list()
        return .object(["count": .number(Double(files.count)), "files": .array(files)])
    }
}
