import UIKit

/// Shows system UI (camera, scanner, share sheet, compose sheets) for a capability and waits for
/// Mu's answer. iOS lets an app present UI only while it is open on screen, so every interactive
/// capability goes through here: it refuses with `foreground_required` when the app is not active,
/// and closes the sheet with `timeout` before the box's job lease (120 s) runs out.
@MainActor
enum Presenter {
    /// Default and ceiling for an interactive job's `timeout` param, in seconds. Kept under the
    /// box's 120 s lease so a sheet Mu walks away from never makes the box re-offer the job.
    nonisolated static let defaultTimeout = 90
    nonisolated static let maxTimeout = 110

    /// The `timeout` param every interactive capability takes (5…110 s, default 90).
    nonisolated static func timeout(_ p: [String: JSONValue]) throws -> Int {
        try Params.int(p, "timeout", in: 5...maxTimeout) ?? defaultTimeout
    }

    static var isForeground: Bool { UIApplication.shared.applicationState == .active }

    static func requireForeground() throws {
        guard isForeground else { throw CapabilityError.foregroundRequired }
    }

    /// The controller currently on top of the key window.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// The active window scene's screen (brightness), without the deprecated `UIScreen.main`.
    static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
    }

    /// Present `build`'s controller and wait until the capability calls `session.finish`, the
    /// timeout passes, or the job is cancelled. The sheet is always dismissed before this returns.
    static func present<T: Sendable>(timeout: Int,
                                     _ build: @MainActor (PresentedSession<T>) throws -> UIViewController) async throws -> T {
        try requireForeground()
        guard let host = topViewController() else { throw CapabilityError.foregroundRequired }
        let session = PresentedSession<T>()
        let controller = try build(session)
        session.controller = controller

        let timer = Task { @MainActor in
            try await Task.sleep(for: .seconds(timeout))
            session.finish(.failure(CapabilityError.timedOut(timeout)))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.continuation = continuation
                host.present(controller, animated: true) { session.onPresented?() }
            }
        } onCancel: {
            Task { @MainActor in session.finish(.failure(CancellationError())) }
        }
    }
}

/// One presentation in flight. Finishing is idempotent: the first answer wins.
@MainActor
final class PresentedSession<T: Sendable> {
    fileprivate var continuation: CheckedContinuation<T, Error>?
    fileprivate weak var controller: UIViewController?
    /// A delegate the presented controller holds only weakly; released when the session ends.
    var keepAlive: AnyObject?
    /// Runs once the controller is on screen (a scanner can only start then).
    var onPresented: (@MainActor () -> Void)?

    func succeed(_ value: T) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let presented = controller
        controller = nil
        keepAlive = nil
        onPresented = nil
        // Resume after the dismissal animation so a following job can present its own sheet.
        if let presented, presented.presentingViewController != nil, !presented.isBeingDismissed {
            presented.dismiss(animated: true) { continuation.resume(with: result) }
        } else {
            continuation.resume(with: result)
        }
    }
}
