import UIKit

/// Finishes a short piece of work even if the app leaves the screen meanwhile: it runs outside
/// the caller's cancellation, under a background-task assertion so iOS gives it time to complete.
/// Used for posting results — after `open.url` or `call` hands Mu to another app, the result of
/// that very job still has to reach the box.
enum BackgroundTime {
    static func run<T: Sendable>(_ name: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let assertion = await Assertion.begin(name)
        defer { Task { @MainActor in assertion.end() } }
        return try await Task.detached { try await work() }.value
    }

    @MainActor
    private final class Assertion {
        private var id: UIBackgroundTaskIdentifier = .invalid

        static func begin(_ name: String) -> Assertion {
            let a = Assertion()
            a.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak a] in a?.end() }
            return a
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
