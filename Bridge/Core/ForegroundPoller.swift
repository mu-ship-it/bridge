import Foundation

/// The foreground connection: a long poll that is re-issued as soon as it returns, so a job the
/// agent queues reaches the phone within a second while the app is open. Runs only while the
/// scene is active (ContentView cancels it on background) — the app never polls hidden.
struct ForegroundPoller {
    /// Seconds the box may hold each request (`GET /bridge/jobs?wait=`).
    static let wait = 25

    /// What to do after one poll. Pure, so the back-off is unit-tested.
    struct Policy: Equatable {
        /// Consecutive failures so far; reset by any success.
        var failures = 0

        /// Seconds to pause before the next poll.
        mutating func delay(after outcome: PollOutcome, elapsed: TimeInterval, pollAfter: Int? = nil) -> TimeInterval {
            switch outcome {
            case .ran(let jobs):
                failures = 0
                // An empty answer long before `wait` means the box ignores `wait` (a v0.1 server):
                // fall back to its suggested interval instead of spinning.
                if jobs == 0 && elapsed < 1 { return TimeInterval(pollAfter ?? 30) }
                return 0
            case .failed, .notConfigured:
                failures += 1
                return min(60, pow(2, Double(min(failures, 6))))   // 2, 4, 8, 16, 32, 60 s
            case .busy:
                return 1   // a push or the Poll-now button is mid-round; join after it
            case .cancelled:
                return 0
            }
        }
    }

    let loop: JobLoop

    func run() async {
        var policy = Policy()
        while !Task.isCancelled {
            let started = Date()
            let outcome = await loop.poll(trigger: "foreground", wait: Self.wait)
            if outcome == .cancelled { return }
            let pause = policy.delay(after: outcome, elapsed: Date().timeIntervalSince(started),
                                     pollAfter: await loop.lastPollAfter)
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        }
    }
}
