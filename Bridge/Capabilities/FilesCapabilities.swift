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

/// Parsed `files.export` params: `metrics` (1–20 health.query metric names), `from` / `to`
/// (ISO-8601, default the last 24 h), `interval` (as health.query, default `raw`), `name`
/// (default `health-<from>_<to>.json`).
struct FilesExportParams: Sendable, Equatable {
    static let maxMetrics = 20
    static let maxBytes = 50_000_000

    let metrics: [String]
    let from: Date
    let to: Date
    let interval: String
    let name: String

    init(_ params: [String: JSONValue]?, now: Date = Date()) throws {
        let p = params ?? [:]
        guard case .array(let raw)? = p["metrics"] else {
            throw CapabilityError.badParams("'metrics' (array of health.query metric names) is required")
        }
        let names = raw.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty, names.count == raw.count else {
            throw CapabilityError.badParams("'metrics' must be a non-empty array of metric names")
        }
        guard names.count <= Self.maxMetrics else { throw CapabilityError.badParams("At most \(Self.maxMetrics) metrics") }
        metrics = names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        interval = p["interval"]?.stringValue ?? "raw"
        // health.query's own parsing: unknown metrics, bad dates and intervals fail before anything runs.
        var range: (Date, Date)?
        for metric in metrics {
            var q = p
            q["metric"] = .string(metric)
            let parsed = try HealthQueryParams(q, now: now)
            range = (parsed.from, parsed.to)
        }
        (from, to) = range!
        if p["name"] != nil {
            name = try FileStore.validName(p)
        } else {
            let day = Date.ISO8601FormatStyle().year().month().day()
            name = "health-\(from.formatted(day))_\(to.formatted(day)).json"
        }
    }

    /// The health.query params for one metric.
    func query(_ metric: String) -> [String: JSONValue] {
        ["metric": .string(metric), "from": .string(ISO.string(from)), "to": .string(ISO.string(to)),
         "interval": .string(interval)]
    }
}

/// `files.export` {metrics, from?, to?, interval?, name?} → runs health.query for each metric and
/// writes one JSON file to the Files-visible Documents folder: `{path, name, bytes, metrics, failed}`.
/// File: `{exported_at, from, to, interval, results: {<metric>: <health.query result> | {error}}}`.
/// A metric that fails (permission, no data type) is recorded in the file and in `failed`; the
/// export fails only if every metric does.
struct FilesExportCapability: Capability {
    let name = "files.export"
    var store = FileStore.documents
    var query: @Sendable (Job) async throws -> JSONValue = { try await HealthQueryCapability().run($0) }

    func run(_ job: Job) async throws -> JSONValue {
        let q = try FilesExportParams(job.params)
        var results: [String: JSONValue] = [:]
        var failed: [JSONValue] = []
        for metric in q.metrics {
            do {
                results[metric] = try await query(Job(id: "\(job.id)-\(metric)", capability: "health.query",
                                                      params: q.query(metric), note: nil))
            } catch {
                let e = error as? CapabilityError
                results[metric] = .object(["error": .object([
                    "code": .string(e?.code ?? "failed"), "message": .string(e?.message ?? error.localizedDescription)])])
                failed.append(.string(metric))
            }
        }
        if failed.count == q.metrics.count, let first = results[q.metrics[0]]?["error"] {
            throw CapabilityError(code: first["code"]?.stringValue ?? "failed",
                                  message: "No metric exported: " + (first["message"]?.stringValue ?? ""))
        }
        let file: JSONValue = .object([
            "exported_at": .string(ISO.string(Date())), "from": .string(ISO.string(q.from)),
            "to": .string(ISO.string(q.to)), "interval": .string(q.interval), "results": .object(results),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        guard data.count <= FilesExportParams.maxBytes else {
            throw CapabilityError.badParams("Export is \(data.count / 1_000_000) MB (max 50); use a shorter range or an interval like 'hour'")
        }
        let bytes = try store.write(q.name, data, append: false)
        return .object([
            "path": .string("On My iPhone/白手套/\(q.name)"),
            "name": .string(q.name),
            "bytes": .number(Double(bytes)),
            "metrics": .number(Double(q.metrics.count - failed.count)),
            "failed": .array(failed),
        ])
    }
}
