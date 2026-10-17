import Foundation

/// Every phone feature the box can call is one small type conforming to this.
protocol Capability: Sendable {
    /// Dotted name used in `Job.capability`, e.g. `health.query`.
    var name: String { get }
    func run(_ job: Job) async throws -> JSONValue
}

/// Throw this from a capability to give the box a machine-readable error code.
struct CapabilityError: Error, LocalizedError, Sendable, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    static func badParams(_ message: String) -> CapabilityError {
        CapabilityError(code: "bad_params", message: message)
    }

    static func unavailable(_ message: String) -> CapabilityError {
        CapabilityError(code: "unavailable", message: message)
    }

    /// Never asked: open the app → Status → the matching "Request …" button.
    static func permissionMissing(_ what: String) -> CapabilityError {
        CapabilityError(code: "permission_missing", message: "\(what) access not granted yet. Open the app → Status → Request \(what).")
    }

    static func permissionDenied(_ what: String) -> CapabilityError {
        CapabilityError(code: "permission_denied", message: "\(what) access denied. Enable it in Settings.")
    }

    /// Mu dismissed the system sheet (camera, scanner, share…) without finishing.
    static let cancelled = CapabilityError(code: "cancelled", message: "Cancelled on the phone")

    /// The capability shows system UI, and iOS only allows that while the app is open on screen.
    static let foregroundRequired = CapabilityError(code: "foreground_required", message: "Needs 白手套 open on screen. Retry when the app is in the foreground.")

    /// Mu did not answer the sheet in time; it was closed so the job finishes inside its lease.
    static func timedOut(_ seconds: Int) -> CapabilityError {
        CapabilityError(code: "timeout", message: "No answer on the phone within \(seconds) s; the sheet was closed")
    }
}

/// Routes jobs to capabilities by name and always produces a result (never throws).
struct JobDispatcher: Sendable {
    private let capabilities: [String: any Capability]

    init(_ capabilities: [any Capability]) {
        self.capabilities = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var names: [String] { capabilities.keys.sorted() }

    func dispatch(_ job: Job, now: @Sendable () -> Date = { Date() }) async -> JobResult {
        let started = ISO.string(now())
        guard let capability = capabilities[job.capability] else {
            return JobResult(jobId: job.id, ok: false,
                             error: JobError(code: "unknown_capability", message: "No capability named '\(job.capability)'. Available: \(names.joined(separator: ", "))"),
                             startedAt: started, finishedAt: ISO.string(now()))
        }
        do {
            let value = try await capability.run(job)
            return JobResult(jobId: job.id, ok: true, result: value, startedAt: started, finishedAt: ISO.string(now()))
        } catch let error as CapabilityError {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: error.code, message: error.message),
                             startedAt: started, finishedAt: ISO.string(now()))
        } catch is CancellationError {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: "cancelled", message: "Job was cancelled (app suspended?)"),
                             startedAt: started, finishedAt: ISO.string(now()))
        } catch {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: "failed", message: error.localizedDescription),
                             startedAt: started, finishedAt: ISO.string(now()))
        }
    }
}

/// Small shared helpers for validating `job.params`.
enum Params {
    /// Optional ISO-8601 / `yyyy-MM-dd` date; present-but-invalid is `bad_params`.
    static func date(_ p: [String: JSONValue], _ key: String) throws -> Date? {
        guard let value = p[key], value != .null else { return nil }
        guard let raw = value.stringValue, let d = ISO.date(raw) else {
            throw CapabilityError.badParams("Bad '\(key)' (use ISO-8601 or yyyy-MM-dd)")
        }
        return d
    }

    /// Optional bool; present-but-invalid is `bad_params`.
    static func bool(_ p: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = p[key], value != .null else { return nil }
        guard let b = value.boolValue else { throw CapabilityError.badParams("'\(key)' must be a boolean") }
        return b
    }

    /// Optional integer clamped to `range`; present-but-invalid is `bad_params`.
    static func int(_ p: [String: JSONValue], _ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = p[key], value != .null else { return nil }
        guard let n = value.doubleValue, n.isFinite else { throw CapabilityError.badParams("'\(key)' must be a number") }
        return min(max(Int(n), range.lowerBound), range.upperBound)
    }

    /// Optional number clamped to `range`; present-but-invalid is `bad_params`.
    static func double(_ p: [String: JSONValue], _ key: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let value = p[key], value != .null else { return nil }
        guard let n = value.doubleValue, n.isFinite else { throw CapabilityError.badParams("'\(key)' must be a number") }
        return min(max(n, range.lowerBound), range.upperBound)
    }

    /// Optional string that must be one of `allowed`; present-but-invalid is `bad_params`.
    static func choice(_ p: [String: JSONValue], _ key: String, _ allowed: [String]) throws -> String? {
        guard let s = try string(p, key) else { return nil }
        let lower = s.lowercased()
        guard allowed.contains(lower) else {
            throw CapabilityError.badParams("'\(key)' must be one of: \(allowed.joined(separator: ", "))")
        }
        return lower
    }

    /// Optional string, trimmed; empty counts as absent.
    static func string(_ p: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = p[key], value != .null else { return nil }
        guard case .string(let s) = value else { throw CapabilityError.badParams("'\(key)' must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
