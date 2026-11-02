import Foundation
import QuartzCore
import UIKit
import os

enum Phase: String, Sendable {
    case individual = "A · each square its own glass"
    case container = "B · one GlassEffectContainer"
    case cooldown = "cooldown"
    case done = "done"
}

struct PhaseResult: Identifiable, Sendable {
    let id: String
    let name: String
    var limit: Int?          // nil = reached the top without failing
    var reason: String
    var worstMs: Double
    var thermal: String
}

struct Sample: Codable, Sendable {
    let phase: String
    let n: Int
    let fps: Double
    let worstMs: Double
    let thermal: String
    let battery: String
    let elapsed: Double
}

@MainActor @Observable
final class Bench {
    static let startN = 10, stepN = 10, maxN = 300
    static let stepSeconds = 8.0
    static let fpsFloor = 50.0
    static let lowSeconds = 3
    static let cooldownSeconds = 10.0

    private(set) var time: TimeInterval = 0          // seconds since start, drives the squares
    private(set) var n = Bench.startN
    private(set) var phase: Phase = .individual
    private(set) var fps = 0.0
    private(set) var worstMs = 0.0
    private(set) var results: [PhaseResult] = []
    private(set) var samples: [Sample] = []
    private(set) var thermal = "nominal"
    private(set) var battery = ""
    let glassAvailable: Bool = { if #available(iOS 26, *) { true } else { false } }()
    let osVersion = UIDevice.current.systemVersion

    @ObservationIgnored private let log = Logger(subsystem: "glassbench", category: "bench")
    @ObservationIgnored private var driver: Driver?
    @ObservationIgnored private var t0 = 0.0
    @ObservationIgnored private var lastFrame = 0.0
    @ObservationIgnored private var windowStart = 0.0
    @ObservationIgnored private var windowFrames = 0
    @ObservationIgnored private var stepStart = 0.0
    @ObservationIgnored private var stepWorst = 0.0
    @ObservationIgnored private var stepFps: [Double] = []
    @ObservationIgnored private var lowRun = 0
    @ObservationIgnored private var phaseStart = 0.0
    @ObservationIgnored private var phaseWorst = 0.0
    @ObservationIgnored private var nextAfterCooldown: Phase = .container

    var isFinished: Bool { phase == .done }

    func start() {
        guard driver == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let d = Driver { [weak self] now in self?.frame(now) }
        driver = d
        d.start()
    }

    private func frame(_ now: CFTimeInterval) {
        if t0 == 0 { t0 = now; lastFrame = now; windowStart = now; stepStart = now; phaseStart = now }
        let dt = now - lastFrame
        lastFrame = now
        time = now - t0
        windowFrames += 1
        stepWorst = max(stepWorst, dt * 1000)
        phaseWorst = max(phaseWorst, dt * 1000)
        worstMs = stepWorst
        guard phase != .done else { return }

        if now - windowStart >= 1 {
            fps = Double(windowFrames) / (now - windowStart)
            windowFrames = 0
            windowStart = now
            readSensors()
            if phase == .cooldown {
                if now - phaseStart >= Self.cooldownSeconds { begin(nextAfterCooldown, now) }
                return
            }
            stepFps.append(fps)
            lowRun = fps < Self.fpsFloor ? lowRun + 1 : 0
            let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            if lowRun >= Self.lowSeconds || hot {
                record(now)
                finishPhase(limit: n, reason: hot ? "thermal serious" : "fps < 50 for 3 s")
                return
            }
        }
        if phase != .cooldown, now - stepStart >= Self.stepSeconds {
            record(now)
            if n + Self.stepN > Self.maxN {
                finishPhase(limit: nil, reason: "reached \(Self.maxN) without failing")
            } else {
                n += Self.stepN
                stepStart = now
                stepWorst = 0
                stepFps = []
            }
        }
    }

    private func readSensors() {
        thermal = Self.name(ProcessInfo.processInfo.thermalState)
        let d = UIDevice.current
        let state: String
        switch d.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "?"
        }
        battery = d.batteryLevel < 0 ? state : "\(state) \(Int(d.batteryLevel * 100))%"
    }

    private func record(_ now: CFTimeInterval) {
        let avg = stepFps.isEmpty ? fps : stepFps.reduce(0, +) / Double(stepFps.count)
        let s = Sample(phase: phase.rawValue, n: n, fps: (avg * 10).rounded() / 10, worstMs: (stepWorst * 10).rounded() / 10,
                       thermal: thermal, battery: battery, elapsed: ((now - t0) * 10).rounded() / 10)
        samples.append(s)
        if let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) {
            log.notice("sample \(text, privacy: .public)")
        }
    }

    private func finishPhase(limit: Int?, reason: String) {
        let name = phase == .individual ? "A · own glass" : "B · container"
        results.append(PhaseResult(id: name, name: name, limit: limit, reason: reason, worstMs: phaseWorst, thermal: thermal))
        log.notice("limit \(name, privacy: .public): \(limit.map(String.init) ?? ">=\(Self.maxN)", privacy: .public) (\(reason, privacy: .public))")
        if phase == .individual {
            nextAfterCooldown = .container
            phase = .cooldown
            n = 0
            phaseStart = lastFrame
        } else {
            phase = .done
            n = 0
        }
    }

    private func begin(_ p: Phase, _ now: CFTimeInterval) {
        phase = p
        n = Self.startN
        stepStart = now
        phaseStart = now
        stepWorst = 0
        phaseWorst = 0
        stepFps = []
        lowRun = 0
    }

    static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "?"
        }
    }
}

@MainActor
private final class Driver: NSObject {
    private let onFrame: (CFTimeInterval) -> Void
    private var link: CADisplayLink?

    init(onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) { onFrame(l.timestamp) }
}

/// Deterministic per-square randomness: the same square on the same cycle always lands in the same place.
enum Leaf {
    static let fall: TimeInterval = 1.6

    static func hash(_ a: UInt64) -> Double {
        var z = a &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    static func r(_ i: Int, _ salt: UInt64, _ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * hash(UInt64(i) &* 131 &+ salt) }

    struct Pose { var x: CGFloat; var y: CGFloat; var rot: Double; var opacity: Double }

    /// Same motion as DeskShatter's leaf fall: sway + drift + tilt over 1.6 s, then respawn at the top.
    static func pose(_ i: Int, at t: TimeInterval, size: CGSize) -> Pose {
        let u = t / fall + r(i, 1, 0, 1)
        let cycle = UInt64(max(0, u.rounded(.down)))
        let f = u - u.rounded(.down)
        let phase = r(i, 2, 0, 2 * .pi), freq = r(i, 3, 1, 2.2), amp = r(i, 4, 10, 24), drift = r(i, 5, -20, 20)
        let sign = hash(UInt64(i) &* 17 &+ 6) < 0.5 ? 8.0 : -8.0
        let tilt = r(i, 7, -7, 7) + sign
        let sw = (sin(phase + f * freq * 2 * .pi) - sin(phase)) * min(1, 3 * f)
        let baseX = hash(UInt64(i) &* 977 &+ cycle &* 7919 &+ 11) * Double(size.width - 24)
        let y = (0.35 * f * f + 0.65 * f) * 1.1 * Double(size.height)
        return Pose(x: CGFloat(baseX + sw * amp + drift * f), y: CGFloat(y - 24),
                    rot: sw * tilt + tilt * 0.3 * f, opacity: f < 0.5 ? 1 : max(0, 1 - (f - 0.5) / 0.5))
    }
}
