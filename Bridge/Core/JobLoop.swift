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
                try await deliver(client)
            }
            let response = try await client.fetchJobs(wait: wait)
            lastPollAfter = response.pollAfterSeconds
            log.info("poll (\(trigger, privacy: .public)): \(response.jobs.count) job(s)")
            await AppStatus.shared.setPending(response.jobs.count)

            // Each result goes out as soon as its job ends: an interactive job (camera, share
            // sheet) can take a minute, and earlier results must not wait behind it past their lease.
            for (index, job) in response.jobs.enumerated() {
                // Backgrounded (e.g. open.url just handed Mu to another app): leave the rest
                // unrun; the box offers them again when their lease runs out.
                try Task.checkCancellation()
                await AppStatus.shared.jobStarted(job)
                let result = await dispatcher.dispatch(job)
                await AppStatus.shared.jobFinished(job, result)
                await AppStatus.shared.setPending(response.jobs.count - index - 1)
                unsent.append(result)
                try await deliver(client)
            }
            await AppStatus.shared.recordPoll(success: true, message: "OK via \(trigger) — \(response.jobs.count) job(s)", unsent: 0)
            return .ran(jobs: response.jobs.count)
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

extension JobLoop {
    /// Posts every unsent result. Not cancelled with the poll and given background time, so a
    /// job that sends Mu to another app (open.url, call, shortcuts.run) still reports back.
    fileprivate func deliver(_ client: BoxClient) async throws {
        let batch = unsent
        guard !batch.isEmpty else { return }
        try await BackgroundTime.run("post results") { try await client.postResults(batch) }
        unsent.removeFirst(batch.count)
    }
}

enum PollOutcome: Equatable, Sendable {
    case ran(jobs: Int)
    case failed
    case notConfigured
    case busy
    case cancelled
}
