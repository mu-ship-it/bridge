import Foundation

/// The foreground connection: a long poll that is re-issued as soon as it returns, so a job the
/// agent queues reaches the phone within a second while the app is open. Runs only while at
/// least one window is in the foreground (ForegroundSession cancels it when the last one leaves)
/// — the app never polls hidden. It never gives up on its own: errors back off, then retry.
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
    /// Told after every round, for the duty banner's connection line.
    var report: @MainActor @Sendable (ConnectionState) -> Void = { _ in }

    func run() async {
        var policy = Policy()
        await report(.connecting)
        while !Task.isCancelled {
            let started = Date()
            let outcome = await loop.poll(trigger: "foreground", wait: Self.wait)
            if outcome == .cancelled { return }
            let pause = policy.delay(after: outcome, elapsed: Date().timeIntervalSince(started),
                                     pollAfter: await loop.lastPollAfter)
            if let state = ConnectionState.after(outcome, pause: pause, failures: policy.failures) {
                await report(state)
            }
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        }
    }
}

/// The foreground connection as the duty banner shows it.
enum ConnectionState: Equatable, Sendable {
    /// No window on screen: nothing polls.
    case idle
    case connecting
    /// The last round reached the box; the next long poll is open (or about to be).
    case live
    case retrying(at: Date, failures: Int)
    case notConfigured

    /// nil = no change (another round was mid-flight, or the loop is stopping).
    static func after(_ outcome: PollOutcome, pause: TimeInterval, failures: Int, now: Date = Date()) -> ConnectionState? {
        switch outcome {
        case .ran: .live
        case .failed: .retrying(at: now.addingTimeInterval(pause), failures: failures)
        case .notConfigured: .notConfigured
        case .busy, .cancelled: nil
        }
    }

    var label: String {
        switch self {
        case .idle: "Not polling (no window on screen)"
        case .connecting: "Connecting…"
        case .live: "Live — long poll open"
        case .retrying(_, let failures): "Box unreachable — retrying (\(failures) failed in a row)"
        case .notConfigured: "Not configured — see Settings"
        }
    }

    var isHealthy: Bool { self == .live }
}
