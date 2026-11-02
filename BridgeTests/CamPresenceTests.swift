import Foundation
import Testing
@testable import Bridge

@Suite struct CamPresenceTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let hit = CamFrame(hit: true, light: 8)
    static let look = CamFrame(hit: true, looking: true, light: 8)
    static let miss = CamFrame(hit: false, light: 8)

    /// A detector fed `frames` one second apart from t0; returns it and the time of the last frame.
    static func fed(_ frames: [CamFrame]) -> CamDetector {
        var d = CamDetector()
        for (i, f) in frames.enumerated() { d.observe(f, now: t0 + TimeInterval(i)) }
        return d
    }

    /// Present at t0+1 (two hits), then misses from `from` up to `until` seconds, every second.
    static func presentThenMisses(until: Int) -> CamDetector {
        var d = fed([hit, hit])
        if until >= 2 { for s in 2...until { d.observe(miss, now: t0 + TimeInterval(s)) } }
        return d
    }

    // MARK: Hysteresis

    @Test func startsUnknown() {
        #expect(CamDetector().state(now: Self.t0) == .unknown)
    }

    @Test func oneHitIsNotArrival_twoInARowAre() {
        #expect(Self.fed([Self.hit]).state(now: Self.t0) == .absent)
        #expect(Self.fed([Self.hit, Self.miss, Self.hit]).state(now: Self.t0 + 2) == .absent)
        #expect(Self.fed([Self.hit, Self.hit]).state(now: Self.t0 + 1) == .present)
    }

    @Test func staysPresentThroughMisses_leavesAfter90sWithoutAHit() {
        // Last hit at t0+1: still present at t0+90 (89 s), gone at t0+91 (90 s).
        #expect(Self.presentThenMisses(until: 90).state(now: Self.t0 + 90) == .present)
        let gone = Self.presentThenMisses(until: 91)
        #expect(gone.state(now: Self.t0 + 91) == .absent)
        #expect(gone.hits == 0 && gone.firstMiss == nil)
    }

    @Test func oneHitDuringTheMissesKeepsHimPresent() {
        var d = Self.presentThenMisses(until: 80)
        d.observe(Self.hit, now: Self.t0 + 81)
        #expect(d.firstMiss == nil)
        for s in 82...170 { d.observe(Self.miss, now: Self.t0 + TimeInterval(s)) }
        #expect(d.state(now: Self.t0 + 170) == .present)   // 89 s since the hit at 81
        d.observe(Self.miss, now: Self.t0 + 171)
        #expect(d.state(now: Self.t0 + 171) == .absent)
    }

    @Test func darkIsItsOwnState_andForgetsPresence() {
        var d = Self.fed([Self.hit, Self.hit])
        d.observe(CamFrame(hit: false, light: -2, dark: true), now: Self.t0 + 2)
        #expect(d.state(now: Self.t0 + 2) == .dark)
        // Light back: one hit is not enough to be present again.
        d.observe(Self.hit, now: Self.t0 + 3)
        #expect(d.state(now: Self.t0 + 3) == .absent)
    }

    @Test func interruptedIsUnknown_notAbsent() {
        var d = Self.fed([Self.hit, Self.hit])
        d.interrupted(now: Self.t0 + 2)
        #expect(d.state(now: Self.t0 + 2) == .unknown)
        #expect(d.light == nil)
    }

    @Test func aStaleStateIsUnknown() {
        let d = Self.fed([Self.hit, Self.hit])
        #expect(d.state(now: Self.t0 + 1 + CamPresence.stale) == .present)
        #expect(d.state(now: Self.t0 + 2 + CamPresence.stale) == .unknown)
    }

    @Test func lookingNeedsAFrontalFace_andHoldsAWhile() {
        let d = Self.fed([Self.hit, Self.look])
        #expect(d.state(now: Self.t0 + 1) == .looking)
        #expect(d.state(now: Self.t0 + 1 + CamPresence.lookHold - 1) == .looking)
        #expect(d.state(now: Self.t0 + 1 + CamPresence.lookHold) == .present)
        // A hit that is not frontal ends it at once; so does a miss.
        #expect(Self.fed([Self.hit, Self.look, Self.hit]).state(now: Self.t0 + 2) == .present)
        #expect(Self.fed([Self.hit, Self.look, Self.miss]).state(now: Self.t0 + 2) == .present)
        // Looking before arrival is not present.
        #expect(Self.fed([Self.look]).state(now: Self.t0) == .absent)
    }

    @Test func frontalAngles() {
        #expect(CamFrame.isLooking(yaw: 0, pitch: 0))
        #expect(CamFrame.isLooking(yaw: -0.3, pitch: 0.3))
        #expect(CamFrame.isLooking(yaw: 0.1, pitch: nil))
        #expect(!CamFrame.isLooking(yaw: 0.5, pitch: 0))
        #expect(!CamFrame.isLooking(yaw: 0, pitch: -0.6))
        #expect(!CamFrame.isLooking(yaw: nil, pitch: 0))
    }

    // MARK: Light

    @Test func ev100FromExposure() {
        // f/2.2, 1/60 s, ISO 100 ≈ EV 8.2 (a lit room); ISO 1600 is 4 stops less.
        let lit = CamFrame.ev100(iso: 100, seconds: 1.0 / 60, aperture: 2.2)!
        #expect(abs(lit - 8.18) < 0.01)
        #expect(abs(CamFrame.ev100(iso: 1600, seconds: 1.0 / 60, aperture: 2.2)! - (lit - 4)) < 0.001)
        #expect(CamFrame.ev100(iso: 0, seconds: 1, aperture: 2) == nil)
    }

    @Test func darkWhenLowEVOrFarUnderTarget() {
        #expect(CamFrame.isDark(ev100: 0.5, targetOffset: 0))
        #expect(CamFrame.isDark(ev100: 3, targetOffset: -2))
        #expect(!CamFrame.isDark(ev100: 3, targetOffset: -1))
        #expect(!CamFrame.isDark(ev100: nil, targetOffset: nil))
    }

    // MARK: Rate

    @Test func samplingRate() {
        let normal = ProcessInfo.ThermalState.nominal
        #expect(CamDetector().interval(now: Self.t0, thermal: normal) == CamPresence.searchInterval)
        // One hit: confirm fast.
        #expect(Self.fed([Self.hit]).interval(now: Self.t0, thermal: normal) == CamPresence.confirmInterval)
        // Present: slow.
        #expect(Self.fed([Self.hit, Self.hit]).interval(now: Self.t0 + 1, thermal: normal) == CamPresence.presentInterval)
        // First miss: one a second for the confirm window, then the search rate until he is gone.
        let missing = Self.presentThenMisses(until: 61)   // first miss at t0+2
        #expect(missing.interval(now: Self.t0 + 61, thermal: normal) == CamPresence.confirmInterval)
        #expect(missing.interval(now: Self.t0 + 62, thermal: normal) == CamPresence.searchInterval)
        // Camera off: the gate is checked on its own beat.
        #expect(CamDetector().interval(now: Self.t0, thermal: normal, cameraOn: false) == CamPresence.gateInterval)
    }

    @Test func seriousHeatHalvesTheRate_criticalStopsTheCamera() {
        let present = Self.fed([Self.hit, Self.hit])
        #expect(present.interval(now: Self.t0 + 1, thermal: .serious) == CamPresence.presentInterval * 2)
        #expect(present.interval(now: Self.t0 + 1, thermal: .fair) == CamPresence.presentInterval)
        #expect(present.wantsCamera(thermal: .serious))
        #expect(!present.wantsCamera(thermal: .critical))
    }

    @Test func aClosedGateNeverTurnsTheCameraOff_itProbesOnceAMinute() {
        let normal = ProcessInfo.ThermalState.nominal
        let idle = CamDetector()
        #expect(idle.wantsCamera(thermal: normal))
        #expect(idle.probing(gateOpen: false) && !idle.probing(gateOpen: true))
        #expect(idle.interval(now: Self.t0, thermal: normal, gateOpen: false) == CamPresence.probeInterval)
        #expect(idle.interval(now: Self.t0, thermal: .serious, gateOpen: false) == CamPresence.probeInterval * 2)
        #expect(idle.interval(now: Self.t0, thermal: normal, gateOpen: true) == CamPresence.searchInterval)
        // Camera off for another reason: the off beat, not the probe.
        #expect(idle.interval(now: Self.t0, thermal: normal, cameraOn: false, gateOpen: false) == CamPresence.gateInterval)
    }

    @Test func aProbeMissIsNoOpinion_soTheRoomSensorDecides() {
        var d = CamDetector()
        d.observe(Self.miss, now: Self.t0, probe: true)
        #expect(d.state(now: Self.t0) == .unknown)
        #expect(d.probing(gateOpen: false))
        // The same miss outside a probe is a real "absent".
        d.observe(Self.miss, now: Self.t0 + 1)
        #expect(d.state(now: Self.t0 + 1) == .absent)
    }

    /// The 米家 sensor offline, Home Assistant still posting its cached "nobody": the gate is closed,
    /// yet a probe that sees Mu brings the camera back to its normal rate and he arrives.
    @Test func aProbeHitOverridesAStuckNobody() {
        let normal = ProcessInfo.ThermalState.nominal
        var d = CamDetector()
        d.observe(Self.miss, now: Self.t0, probe: d.probing(gateOpen: false))
        #expect(d.interval(now: Self.t0, thermal: normal, gateOpen: false) == CamPresence.probeInterval)
        let probeAt = Self.t0 + CamPresence.probeInterval
        d.observe(Self.hit, now: probeAt, probe: d.probing(gateOpen: false))
        #expect(!d.probing(gateOpen: false))
        #expect(d.interval(now: probeAt, thermal: normal, gateOpen: false) == CamPresence.confirmInterval)
        d.observe(Self.hit, now: probeAt + 1, probe: d.probing(gateOpen: false))
        #expect(d.state(now: probeAt + 1) == .present)
        // Present: the closed gate changes nothing; he leaves only after 90 s unseen.
        #expect(d.interval(now: probeAt + 1, thermal: normal, gateOpen: false) == CamPresence.presentInterval)
        #expect(BrightnessPolicy.isPresent(camera: d.state(now: probeAt + 1), nil, fetchedAt: nil, now: probeAt + 1))
        for s in 2...91 { d.observe(Self.miss, now: probeAt + TimeInterval(s), probe: d.probing(gateOpen: false)) }
        #expect(d.state(now: probeAt + 91) == .absent)
        #expect(d.interval(now: probeAt + 91, thermal: normal, gateOpen: false) == CamPresence.probeInterval)
    }

    /// A probe hit followed by a miss is not an arrival; back to probing.
    @Test func aLoneProbeHitFallsBackToProbing() {
        var d = CamDetector()
        d.observe(Self.hit, now: Self.t0, probe: true)
        d.observe(Self.miss, now: Self.t0 + 1, probe: d.probing(gateOpen: false))
        #expect(d.state(now: Self.t0 + 1) != .present)
        #expect(d.interval(now: Self.t0 + 1, thermal: .nominal, gateOpen: false) == CamPresence.probeInterval)
    }

    // MARK: Gate

    static func sensor(occupied: Bool?, fresh: Bool = true, age: Int = 10) -> DeskPayload.Presence.RoomSensor {
        DeskPayload.Presence.RoomSensor(occupied: occupied, fresh: fresh, ageS: age, staleAfterS: 180)
    }

    @Test func gateClosesOnlyOnAFreshEmptyRoom() {
        let t = Self.t0
        #expect(!CamGate.open(Self.sensor(occupied: false), fetchedAt: t, now: t))
        #expect(CamGate.open(Self.sensor(occupied: true), fetchedAt: t, now: t))
        #expect(CamGate.open(Self.sensor(occupied: nil), fetchedAt: t, now: t))
        #expect(CamGate.open(Self.sensor(occupied: false, fresh: false), fetchedAt: t, now: t))
        #expect(CamGate.open(nil, fetchedAt: t, now: t))
        // The reading ages on the phone too, and an old payload is not trusted at all.
        #expect(!CamGate.open(Self.sensor(occupied: false), fetchedAt: t, now: t + 170))
        #expect(CamGate.open(Self.sensor(occupied: false), fetchedAt: t, now: t + 171))
        #expect(CamGate.open(Self.sensor(occupied: false, age: 0), fetchedAt: t, now: t + CamPresence.payloadStale + 1))
        #expect(CamGate.open(Self.sensor(occupied: false), fetchedAt: nil, now: t))
    }

    @Test func decodesTheRoomSensor() throws {
        let json = #"{"present": false, "source": "pc", "idle_s": 400, "age_s": 3, "stale_after_s": 90,"#
            + #" "room_sensor": {"occupied": false, "fresh": true, "age_s": 20, "stale_after_s": 180}}"#
        let presence = try JSONDecoder().decode(DeskPayload.Presence.self, from: Data(json.utf8))
        #expect(presence.roomSensor == Self.sensor(occupied: false, age: 20))
        let old = #"{"present": true, "source": "pc", "idle_s": 4, "age_s": 3, "stale_after_s": 90}"#
        #expect(try JSONDecoder().decode(DeskPayload.Presence.self, from: Data(old.utf8)).roomSensor == nil)
    }

    // MARK: What the desk does with it

    @Test func cameraOpinionWinsOverTheBox_darkAndUnknownFallBack() {
        let box = DeskPayload.Presence(present: true, source: "pc", idleS: 2, ageS: 1, staleAfterS: 90)
        let t = Self.t0
        #expect(!BrightnessPolicy.isPresent(camera: .absent, box, fetchedAt: t, now: t))
        #expect(BrightnessPolicy.isPresent(camera: .looking, nil, fetchedAt: nil, now: t))
        #expect(BrightnessPolicy.isPresent(camera: .dark, box, fetchedAt: t, now: t))
        #expect(BrightnessPolicy.isPresent(camera: .unknown, box, fetchedAt: t, now: t))
        #expect(!BrightnessPolicy.isPresent(camera: .unknown, nil, fetchedAt: t, now: t))
    }

    @Test func brightOnlyWhenLooking_capsInADimRoom() {
        let noon = DeskBrightnessTests.at(12)
        let cal = DeskBrightnessTests.shanghai
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: cal, looking: true) == 0.85)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: cal, looking: false) == 0.3)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: cal, looking: nil) == 0.85)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: cal, looking: true, light: 2) == 0.5)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: cal, looking: true, light: 9) == 0.85)
        // A new item still lights it up while he looks away.
        #expect(BrightnessPolicy.level(present: true, lastArrival: noon, now: noon + 5, calendar: cal, looking: false) == 0.85)
        #expect(BrightnessPolicy.level(present: false, lastArrival: nil, now: noon, calendar: cal, looking: nil, light: 9) == 0.10)
    }

    @Test func facePerksUpOnAGlance_belowEverythingElse() {
        var input = FaceInput()
        input.looking = true
        #expect(Face.mood(input) == .perky && Mood.perky.face == "(^‿^)")
        input.lanes = 1
        #expect(Face.mood(input) == .busy)
    }

    @Test func heatRowIsLocalAndTerse() {
        #expect(CamHeat.isLocal(CamHeat.item) && CamHeat.item.isWarning)
        #expect(CamHeat.item.text == "cam paused: heat")
    }

    // MARK: Telling the box

    @Test func reportsOnChange_andKeepsADecisiveStateFresh() {
        let t = Self.t0
        typealias K = CamReport.Key
        #expect(CamReport.due(K(state: .unknown), last: nil, now: t))
        #expect(CamReport.due(K(state: .present), last: (K(state: .unknown), t), now: t + 1))
        #expect(!CamReport.due(K(state: .present), last: (K(state: .present), t), now: t + CamReport.every - 1))
        #expect(CamReport.due(K(state: .present), last: (K(state: .present), t), now: t + CamReport.every))
        #expect(CamReport.due(K(state: .dark), last: (K(state: .dark), t), now: t + CamReport.every))
        // Unknown goes out once: silence reads the same on the box.
        #expect(!CamReport.due(K(state: .unknown), last: (K(state: .unknown), t), now: t + 3600))
        #expect(CamReport.every * 2 <= 60)   // the box's CAMERA_STALE_SECONDS
        // A new verdict or sitting down goes out at once.
        #expect(CamReport.due(K(state: .present, who: .mu), last: (K(state: .present), t), now: t + 1))
        #expect(CamReport.due(K(state: .present, seated: true), last: (K(state: .present), t), now: t + 1))
    }

    @Test func theReportCarriesOnlyTheState() throws {
        let report = CamReport(device: "desk-mini", state: .looking, light: 7.26, now: Self.t0)
        let config = BridgeConfig(baseURL: URL(string: "https://box.example")!, token: "t", deviceId: "desk-mini")
        let r = try BoxClient(config: config).cameraRequest(report)
        #expect(r.url?.path() == "/bridge/presence/camera" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["device", "state", "ts", "light", "who", "seated"])
        #expect(body?["who"] as? String == "unknown" && body?["seated"] as? Bool == false)
        #expect(body?["state"] as? String == "looking" && body?["light"] as? Double == 7.3)
        #expect((body?["ts"] as? String)?.hasSuffix("Z") == true)
        #expect(CamReport(device: "d", state: .dark, light: -99, now: Self.t0).light == -20)
    }

    @Test func theReportCarriesWhoAndSeated_neverAnEmbedding() throws {
        let report = CamReport(device: "desk-mini", state: .present, light: 6, now: Self.t0, who: .mu, score: 0.61234, seated: true)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["device", "state", "ts", "light", "who", "score", "seated"])
        #expect(body?["who"] as? String == "mu" && body?["score"] as? Double == 0.612 && body?["seated"] as? Bool == true)
    }

    @Test func identifyingKeepsTheConfirmRateWhilePresent() {
        let d = Self.fed([Self.hit, Self.hit])
        #expect(d.interval(now: Self.t0 + 2, thermal: .nominal) == CamPresence.presentInterval)
        #expect(d.interval(now: Self.t0 + 2, thermal: .nominal, identifying: true) == CamPresence.confirmInterval)
        #expect(!CamDetector().probing(gateOpen: false, identifying: true))
    }
}
