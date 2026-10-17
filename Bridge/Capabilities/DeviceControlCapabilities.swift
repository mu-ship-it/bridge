import AVFoundation
import UIKit

/// `haptic` {style?} → one tap of the Taptic Engine: `{style}`.
/// Styles: `light`, `medium` (default), `heavy`, `soft`, `rigid`, `selection`, `success`, `warning`, `error`.
struct HapticParams: Sendable, Equatable {
    static let styles = ["light", "medium", "heavy", "soft", "rigid", "selection", "success", "warning", "error"]
    let style: String

    init(_ params: [String: JSONValue]?) throws {
        style = try Params.choice(params ?? [:], "style", Self.styles) ?? "medium"
    }
}

struct HapticCapability: Capability {
    let name = "haptic"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try HapticParams(job.params)
        try await MainActor.run {
            // iOS plays haptics only for the app on screen.
            try Presenter.requireForeground()
            switch q.style {
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            default:
                let style: UIImpactFeedbackGenerator.FeedbackStyle = switch q.style {
                case "light": .light
                case "heavy": .heavy
                case "soft": .soft
                case "rigid": .rigid
                default: .medium
                }
                UIImpactFeedbackGenerator(style: style).impactOccurred()
            }
        }
        return .object(["style": .string(q.style)])
    }
}

/// `torch` {on, level?} → the flashlight: `{on, level}`. `level` 0.01–1 (default 1) applies when on.
struct TorchParams: Sendable, Equatable {
    let on: Bool
    let level: Float

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let on = try Params.bool(p, "on") else { throw CapabilityError.badParams("'on' (boolean) is required") }
        self.on = on
        level = Float(try Params.double(p, "level", in: 0.01...1) ?? 1)
    }
}

struct TorchCapability: Capability {
    let name = "torch"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try TorchParams(job.params)
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, device.isTorchAvailable else {
            throw CapabilityError.unavailable("No flashlight available (simulator, or the camera is in use / phone too hot)")
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if q.on {
                try device.setTorchModeOn(level: min(q.level, AVCaptureDevice.maxAvailableTorchLevel))
            } else {
                device.torchMode = .off
            }
        } catch {
            throw CapabilityError.unavailable("Flashlight busy: \(error.localizedDescription)")
        }
        return .object(["on": .bool(device.torchMode == .on), "level": .number(Double(device.torchLevel))])
    }
}

/// `screen.brightness` {level} → sets the display brightness 0–1: `{level, previous}`.
/// iOS may put the previous level back when the phone locks or 白手套 leaves the screen.
struct ScreenBrightnessParams: Sendable, Equatable {
    let level: Double

    init(_ params: [String: JSONValue]?) throws {
        guard let level = try Params.double(params ?? [:], "level", in: 0...1) else {
            throw CapabilityError.badParams("'level' (0–1) is required")
        }
        self.level = level
    }
}

struct ScreenBrightnessCapability: Capability {
    let name = "screen.brightness"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ScreenBrightnessParams(job.params)
        let previous: Double = try await MainActor.run {
            try Presenter.requireForeground()
            guard let screen = Presenter.screen else { throw CapabilityError.foregroundRequired }
            let previous = Double(screen.brightness)
            screen.brightness = CGFloat(q.level)
            return previous
        }
        return .object(["level": .number(q.level), "previous": .number((previous * 100).rounded() / 100)])
    }
}
