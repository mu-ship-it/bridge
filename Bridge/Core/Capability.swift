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
