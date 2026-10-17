import Foundation
import os

/// Base behaviour 1: GET jobs → run each by capability → POST results.
/// Triggered by the foreground long poll (ForegroundPoller), silent push, BG refresh and
/// significant location changes.
actor JobLoop {
    private let dispatcher: JobDispatcher
    private var running = false
    /// Results we computed but failed to deliver; retried first on the next poll.
    private var unsent: [JobResult] = []
    /// The box's last `poll_after_seconds` hint, for a box that does not long-poll.
    private(set) var lastPollAfter: Int?
    private let log = Logger(subsystem: AppInfo.bundleID, category: "jobs")

    init(dispatcher: JobDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Returns true if any job was executed.
    @discardableResult
    func pollOnce(trigger: String = "manual") async -> Bool {
        if case .ran(let jobs) = await poll(trigger: trigger) { return jobs > 0 }
        return false
    }

    /// One GET jobs → run → POST results round. `wait` makes the GET a long poll.
    func poll(trigger: String, wait: Int? = nil) async -> PollOutcome {
        guard !running else { return .busy }
        running = true
        defer { running = false }

        guard let config = ConfigStore.load() else {
            await AppStatus.shared.recordPoll(success: false, message: "Not configured", unsent: unsent.count)
            return .notConfigured
        }
        let client = BoxClient(config: config)
        do {
            if !unsent.isEmpty {
                try await client.postResults(unsent)
                unsent.removeAll()
            }
            let response = try await client.fetchJobs(wait: wait)
            lastPollAfter = response.pollAfterSeconds
            log.info("poll (\(trigger, privacy: .public)): \(response.jobs.count) job(s)")
            await AppStatus.shared.setPending(response.jobs.count)

            var results: [JobResult] = []
            for (index, job) in response.jobs.enumerated() {
                await AppStatus.shared.jobStarted(job)
                let result = await dispatcher.dispatch(job)
                results.append(result)
                await AppStatus.shared.jobFinished(job, result)
                await AppStatus.shared.setPending(response.jobs.count - index - 1)
            }
            if !results.isEmpty {
                unsent.append(contentsOf: results)
                try await client.postResults(unsent)
                unsent.removeAll()
            }
            await AppStatus.shared.recordPoll(success: true, message: "OK via \(trigger) — \(results.count) job(s)", unsent: 0)
            return .ran(jobs: results.count)
        } catch is CancellationError {
            // Backgrounded mid-poll: not an error. Anything leased but unrun is re-offered by the box.
            return .cancelled
        } catch {
            log.error("poll failed: \(error.localizedDescription, privacy: .public)")
            await AppStatus.shared.recordPoll(success: false, message: error.localizedDescription, unsent: unsent.count)
            return .failed
        }
    }
}

enum PollOutcome: Equatable, Sendable {
    case ran(jobs: Int)
    case failed
    case notConfigured
    case busy
    case cancelled
}
