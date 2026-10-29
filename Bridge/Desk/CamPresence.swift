import Foundation

/// The desk camera's presence detector: whether Mu is at the desk and looking at it, from the
/// phone's own front camera (DeskCamera). Pure, so the hysteresis and the sampling rate are
/// pinned by tests; every threshold is here.
///
/// Privacy: frames never leave DeskCamera. What reaches this file, the box and the logs is a
/// `CamFrame` (hit / looking / light) and the resulting `CamState`.
enum CamPresence {
    /// Hits in a row that mean Mu arrived.
    static let arriveHits = 2
    /// No hit for this long while present means he left.
    static let leaveAfter: TimeInterval = 90
    /// One frame every this many seconds while he is present.
    static let presentInterval: TimeInterval = 7
    /// After the first miss (or a first hit): one frame a second, for `confirmWindow`.
    static let confirmInterval: TimeInterval = 1
    static let confirmWindow: TimeInterval = 60
    /// Looking for him: the camera may run (the room is occupied or unknown) but he is not seen yet.
    static let searchInterval: TimeInterval = 3
    /// Camera off because the room is empty: how often the gate is checked again.
    static let gateInterval: TimeInterval = 5
    /// `ProcessInfo.ThermalState.serious` halves the rate.
    static let hotFactor: Double = 2
    /// A face counts as looking at the screen when |yaw| and |pitch| are under these (radians, ~20°).
    static let lookYaw = 0.35
    static let lookPitch = 0.35
    /// A frontal frame keeps `looking` for this long (covers one hot present interval).
    static let lookHold: TimeInterval = 15
    /// Too dark to see: EV100 under `darkEV`, or the exposure short of its target by more than `darkOffset` EV.
    static let darkEV = 1.0
    static let darkOffset = -1.5
    /// No frame for this long while the camera should be running: the camera counts as interrupted.
    static let frameTimeout: TimeInterval = 5
    /// The phone stops trusting its own camera state this long after the last sample.
    static let stale: TimeInterval = 30
    /// Room light (EV100) under this caps the desk's bright level at the night level.
    static let dimRoomEV = 4.0
    /// The box's room sensor reading is trusted for gating only while the desk payload is this fresh.
    static let payloadStale: TimeInterval = 180
}

/// What the phone reports: `unknown` covers "camera off", "interrupted", "permission denied" and
/// "paused for heat" — anything that is not an opinion about Mu.
enum CamState: String, Sendable, Equatable {
    case present, looking, absent, dark, unknown

    /// An opinion the desk can act on; `dark` and `unknown` leave presence to the room sensor.
    var isDecisive: Bool { self == .present || self == .looking || self == .absent }
    var isPresent: Bool { self == .present || self == .looking }
}

/// One analysed frame, reduced to what the detector needs.
struct CamFrame: Equatable, Sendable {
    /// A face or an upper body.
    var hit: Bool
    /// The face is roughly frontal (CamPresence.lookYaw / lookPitch).
    var looking = false
    /// Rough room brightness, EV100 from the camera's own exposure; nil when unreadable.
    var light: Double?
    /// Too dark for Vision to be trusted.
    var dark = false

    /// Frontal enough to count as a glance at the screen. Missing angles count as not looking.
    static func isLooking(yaw: Double?, pitch: Double?) -> Bool {
        guard let yaw, abs(yaw) < CamPresence.lookYaw else { return false }
        return abs(pitch ?? 0) < CamPresence.lookPitch
    }

    /// EV100 from ISO, exposure time (s) and aperture (f-number).
    static func ev100(iso: Double, seconds: Double, aperture: Double) -> Double? {
        guard iso > 0, seconds > 0, aperture > 0 else { return nil }
        return log2(aperture * aperture / seconds) - log2(iso / 100)
    }

    static func isDark(ev100: Double?, targetOffset: Double?) -> Bool {
        if let ev100, ev100 < CamPresence.darkEV { return true }
        if let targetOffset, targetOffset < CamPresence.darkOffset { return true }
        return false
    }
}

/// Schmitt-trigger presence: two hits in a row to arrive, 90 s without one to leave.
struct CamDetector: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case unknown, dark, absent, present }

    private(set) var phase = Phase.unknown
    /// Hits in a row (0 after any miss).
    private(set) var hits = 0
    private(set) var lastHit: Date?
    /// The first miss of the current run of misses while present.
    private(set) var firstMiss: Date?
    private(set) var lastLook: Date?
    private(set) var light: Double?
    private(set) var lastSample: Date?

    mutating func observe(_ frame: CamFrame, now: Date) {
        lastSample = now
        light = frame.light
        if frame.dark {
            reset(to: .dark)
            return
        }
        guard frame.hit else {
            hits = 0
            lastLook = nil
            guard phase == .present else { phase = .absent; return }
            if firstMiss == nil { firstMiss = now }
            if now.timeIntervalSince(lastHit ?? now) >= CamPresence.leaveAfter { reset(to: .absent) }
            return
        }
        hits += 1
        lastHit = now
        firstMiss = nil
        lastLook = frame.looking ? now : nil
        phase = phase == .present || hits >= CamPresence.arriveHits ? .present : .absent
    }

    /// The camera stopped giving frames (another app took it, permission denied, the app left the
    /// screen, heat, or the room gate closed): no opinion until it comes back.
    mutating func interrupted(now: Date) {
        reset(to: .unknown)
        light = nil
        lastSample = now
    }

    private mutating func reset(to phase: Phase) {
        self.phase = phase
        hits = 0
        lastHit = nil
        firstMiss = nil
        lastLook = nil
    }

    func state(now: Date) -> CamState {
        if let lastSample, now.timeIntervalSince(lastSample) > CamPresence.stale { return .unknown }
        switch phase {
        case .unknown: return .unknown
        case .dark: return .dark
        case .absent: return .absent
        case .present:
            if let lastLook, now.timeIntervalSince(lastLook) < CamPresence.lookHold { return .looking }
            return .present
        }
    }

    /// Whether the camera should be running. The room gate only decides while Mu is not seen:
    /// once he is present the camera stays on until it sees him leave. Critical heat always stops it.
    func wantsCamera(gateOpen: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        guard thermal != .critical else { return false }
        return gateOpen || phase == .present
    }

    /// Seconds to the next frame (or, with the camera off, to the next gate check).
    func interval(now: Date, thermal: ProcessInfo.ThermalState, cameraOn: Bool = true) -> TimeInterval {
        let base: TimeInterval
        if !cameraOn {
            base = CamPresence.gateInterval
        } else if phase == .present {
            if let firstMiss, now.timeIntervalSince(firstMiss) < CamPresence.confirmWindow {
                base = CamPresence.confirmInterval
            } else if firstMiss != nil {
                base = CamPresence.searchInterval
            } else {
                base = CamPresence.presentInterval
            }
        } else if hits > 0 {
            base = CamPresence.confirmInterval
        } else {
            base = CamPresence.searchInterval
        }
        return thermal == .serious ? base * CamPresence.hotFactor : base
    }
}

/// Whether the room lets the camera run: off only when the box says its room sensor is fresh and
/// reads nobody. No sensor, a stale reading, or a stale desk payload all leave the camera allowed.
enum CamGate {
    static func open(_ sensor: DeskPayload.Presence.RoomSensor?, fetchedAt: Date?, now: Date) -> Bool {
        guard let sensor, let fetchedAt, now.timeIntervalSince(fetchedAt) <= CamPresence.payloadStale else { return true }
        guard sensor.fresh, sensor.occupied == false else { return true }
        if let ageS = sensor.ageS, let staleAfter = sensor.staleAfterS,
           TimeInterval(ageS) + now.timeIntervalSince(fetchedAt) > TimeInterval(staleAfter) { return true }
        return false
    }
}

/// The terse Attention row shown while critical heat keeps the camera off. Local to the phone:
/// never posted, never acknowledged, gone when the phone cools down.
enum CamHeat {
    static let id = "local.cam.heat"
    static let item = DeskPayload.Item(id: id, kind: "alert", text: "cam paused: heat", level: "warn", ts: "")

    static func isLocal(_ item: DeskPayload.Item) -> Bool { item.id == id }
}
