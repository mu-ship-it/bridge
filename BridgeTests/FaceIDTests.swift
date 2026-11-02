import Foundation
import Testing
@testable import Bridge

@Suite struct FaceIDTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A unit vector along axis `i` (128-d), nudged by `jitter` on axis `i + 1`: same person, new frame.
    static func vec(_ i: Int, jitter: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 128)
        v[i] = 1
        v[(i + 1) % 128] = jitter
        return v
    }

    /// A vector whose cosine with `vec(0)` is exactly `c`.
    static func at(_ c: Double) -> [Float] {
        var v = [Float](repeating: 0, count: 128)
        v[0] = Float(c)
        v[5] = Float((1 - c * c).squareRoot())
        return v
    }

    static let mu = vec(0)
    static let mom = vec(40)

    static func read(_ v: [Float]) -> FaceRead { FaceRead(embedding: v, quality: 0.8) }

    /// Enrolled on `mu` from `n` PC-active samples, `FaceID.fillEvery` apart from t0.
    static func enrolled(_ n: Int = FaceID.samplesMin) -> (FaceEnrollment, Date) {
        var e = FaceEnrollment()
        var t = t0
        for k in 0..<n {
            let took1 = e.offer(read(vec(0, jitter: Float(k % 3) * 0.05)), pcActive: true, now: t)
            #expect(took1)
            t += FaceID.fillEvery
        }
        return (e, t)
    }

    // MARK: Matching

    @Test func cosineAndVerdictBands() {
        #expect(abs(FaceID.cosine(Self.mu, Self.mu) - 1) < 1e-9)
        #expect(FaceID.cosine(Self.mu, Self.mom) == 0)
        #expect(FaceID.cosine(Self.mu, [1, 2]) == 0)   // length mismatch: no match
        #expect(FaceID.verdict(similarity: FaceID.matchSimilarity) == .mu)
        #expect(FaceID.verdict(similarity: FaceID.matchSimilarity - 0.01) == nil)
        #expect(FaceID.verdict(similarity: FaceID.otherSimilarity) == nil)
        #expect(FaceID.verdict(similarity: FaceID.otherSimilarity - 0.01) == .other)
        #expect(FaceID.verdict(similarity: nil) == nil)
        #expect(FaceID.otherSimilarity < FaceID.guardSimilarity && FaceID.guardSimilarity < FaceID.matchSimilarity)
    }

    @Test func onlyFrontalSharpBigFacesAreRead() {
        #expect(FaceID.isReadable(yaw: 0.1, pitch: 0.1, quality: 0.5, widthPixels: 90))
        #expect(!FaceID.isReadable(yaw: 0.6, pitch: 0, quality: 0.5, widthPixels: 90))     // side face
        #expect(!FaceID.isReadable(yaw: nil, pitch: 0, quality: 0.5, widthPixels: 90))
        #expect(!FaceID.isReadable(yaw: 0, pitch: 0.5, quality: 0.5, widthPixels: 90))     // looking down
        #expect(!FaceID.isReadable(yaw: 0, pitch: 0, quality: 0.2, widthPixels: 90))       // blurred / dim
        #expect(!FaceID.isReadable(yaw: 0, pitch: 0, quality: nil, widthPixels: 90))
        #expect(!FaceID.isReadable(yaw: 0, pitch: 0, quality: 0.5, widthPixels: 40))       // across the room
    }

    // MARK: Enrollment

    @Test func notEnrolledUntilFiveSamples_andNothingWithoutThePC() {
        var e = FaceEnrollment()
        let took2 = e.offer(Self.read(Self.mu), pcActive: false, now: Self.t0)
        #expect(!took2)
        #expect(e.samples.isEmpty && e.similarity(Self.mu) == nil)
        let (four, _) = Self.enrolled(FaceID.samplesMin - 1)
        #expect(!four.isEnrolled && four.similarity(Self.mu) == nil)
        let (five, _) = Self.enrolled()
        #expect(five.isEnrolled && (five.similarity(Self.mu) ?? 0) > 0.99)
        #expect(five.spread > 0 && five.spread < 0.01)
    }

    @Test func fillsAtMostOneSampleEveryTwentySeconds() {
        var e = FaceEnrollment()
        let took3 = e.offer(Self.read(Self.mu), pcActive: true, now: Self.t0)
        #expect(took3)
        let took4 = e.offer(Self.read(Self.mu), pcActive: true, now: Self.t0 + FaceID.fillEvery - 1)
        #expect(!took4)
        let took5 = e.offer(Self.read(Self.mu), pcActive: true, now: Self.t0 + FaceID.fillEvery)
        #expect(took5)
        #expect(e.samples.count == 2)
    }

    @Test func whileFilling_aFaceThatDisagreesStartsTheSetOver() {
        // Mom typed first (one sample), then Mu: the set restarts on Mu and settles there.
        var e = FaceEnrollment()
        var t = Self.t0
        let took6 = e.offer(Self.read(Self.mom), pcActive: true, now: t)
        #expect(took6)
        t += FaceID.fillEvery
        let took7 = e.offer(Self.read(Self.mu), pcActive: true, now: t)
        #expect(took7)
        #expect(e.samples.count == 1 && FaceID.cosine(e.template, Self.mu) > 0.99)
    }

    @Test func onceEnrolled_someoneElseAtThePCTeachesNothing() {
        var (e, t) = Self.enrolled()
        let before = e
        let took8 = e.offer(Self.read(Self.mom), pcActive: true, now: t)
        #expect(!took8)
        #expect(e == before)
        let took9 = e.offer(Self.read(Self.at(FaceID.guardSimilarity - 0.02)), pcActive: true, now: t)
        #expect(!took9)
        let took10 = e.offer(Self.read(Self.at(FaceID.guardSimilarity + 0.02)), pcActive: true, now: t)
        #expect(took10)
    }

    @Test func keepsTwentySamples_thenRefreshesSlowlyByMovingAverage() {
        var (e, t) = Self.enrolled(FaceID.samplesMax)
        #expect(e.isFull && e.samples.count == FaceID.samplesMax)
        // Once full: one sample per refresh interval.
        let took11 = e.offer(Self.read(Self.mu), pcActive: true, now: t)
        #expect(!took11)
        t = (e.lastSample ?? t) + FaceID.refreshEvery
        let before = e.template
        let shifted = Self.at(0.8)   // Mu in new light
        let took12 = e.offer(Self.read(shifted), pcActive: true, now: t)
        #expect(took12)
        #expect(e.samples.count == FaceID.samplesMax)
        // The template moves toward the new sample by about the EMA weight, not all the way.
        let moved = FaceID.cosine(e.template, shifted) - FaceID.cosine(before, shifted)
        #expect(moved > 0 && moved < 0.05)
        #expect(FaceID.cosine(e.template, Self.mu) > 0.98)
    }

    @Test func longPressBurst_takesTenFacesWithoutThePC_thenStops() {
        var e = FaceEnrollment()
        e.startManual(now: Self.t0)
        var t = Self.t0
        var taken = 0
        for _ in 0..<20 {
            if e.offer(Self.read(Self.mu), pcActive: false, now: t) { taken += 1 }
            t += FaceID.manualEvery
        }
        #expect(taken == FaceID.manualSamples && e.isEnrolled)
        #expect(!e.isManual(now: t))
        // The burst also ends on its own after its window.
        var late = FaceEnrollment()
        late.startManual(now: Self.t0)
        let took13 = late.offer(Self.read(Self.mu), pcActive: false, now: Self.t0 + FaceID.manualWindow)
        #expect(!took13)
    }

    @Test func longPressBurst_relearnsAPollutedTemplate() {
        // Enrolled on the wrong face somehow: a burst of Mu outweighs it.
        var e = FaceEnrollment()
        var t = Self.t0
        for _ in 0..<FaceID.samplesMin { _ = e.offer(Self.read(Self.mom), pcActive: true, now: t); t += FaceID.fillEvery }
        e.startManual(now: t)
        for _ in 0..<FaceID.manualSamples { _ = e.offer(Self.read(Self.mu), pcActive: false, now: t); t += FaceID.manualEvery }
        #expect((e.similarity(Self.mu) ?? 0) > (e.similarity(Self.mom) ?? 1))
    }

    @Test func storesEmbeddingsOnly_notTheBurst() throws {
        var (e, _) = Self.enrolled()
        e.startManual(now: Self.t0)
        let data = try JSONEncoder().encode(e)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys).isSubset(of: ["samples", "template", "spread", "lastSample"]) && keys.contains("samples"))
        let back = try JSONDecoder().decode(FaceEnrollment.self, from: data)
        #expect(back.samples == e.samples && back.template == e.template && !back.isManual(now: Self.t0))
    }

    @Test func clearForgetsMu() {
        var (e, _) = Self.enrolled()
        e.clear()
        #expect(e.samples.isEmpty && !e.isEnrolled)
    }

    // MARK: Who

    @Test func twoAgreeingReadsDecide_andAGreyOrMissingReadChangesNothing() {
        var w = WhoTracker()
        w.observe(similarity: 0.7, now: Self.t0)
        #expect(w.who(now: Self.t0) == .unknown)
        w.observe(similarity: nil, now: Self.t0 + 1)         // side face
        w.observe(similarity: 0.3, now: Self.t0 + 2)         // grey band
        w.observe(similarity: 0.7, now: Self.t0 + 3)
        #expect(w.who(now: Self.t0 + 3) == .mu && w.score == 0.7)
        // One odd frame does not flip him to other.
        w.observe(similarity: 0.1, now: Self.t0 + 4)
        #expect(w.who(now: Self.t0 + 4) == .mu)
        w.observe(similarity: 0.1, now: Self.t0 + 5)
        #expect(w.who(now: Self.t0 + 5) == .other)
    }

    @Test func greyBandAndNoTemplateAreUnknown_neverOther() {
        var w = WhoTracker()
        for s in 0..<10 { w.observe(similarity: 0.3, now: Self.t0 + TimeInterval(s)) }
        #expect(w.who(now: Self.t0 + 10) == .unknown)
        var none = WhoTracker()
        for s in 0..<10 { none.observe(similarity: nil, now: Self.t0 + TimeInterval(s)) }
        #expect(none.who(now: Self.t0 + 10) == .unknown && none.score == nil)
    }

    @Test func aVerdictIsHeld_thenFades() {
        var w = WhoTracker()
        w.observe(similarity: 0.7, now: Self.t0)
        w.observe(similarity: 0.7, now: Self.t0 + 1)
        #expect(w.who(now: Self.t0 + 1 + FaceID.verdictHold - 1) == .mu)
        #expect(w.who(now: Self.t0 + 1 + FaceID.verdictHold) == .unknown)
    }

    // MARK: Seated

    static func seat(_ steps: [(Bool, Double)], every: TimeInterval = 1) -> (SeatTracker, Date) {
        var s = SeatTracker()
        var t = t0
        for (hit, x) in steps {
            s.observe(hit: hit, center: hit ? (x, 0.5) : nil, now: t)
            t += every
        }
        return (s, t - every)
    }

    @Test func seatedAfterTenSteadySeconds() {
        #expect(!Self.seat(Array(repeating: (true, 0.5), count: 10)).0.seated)   // 9 s
        #expect(Self.seat(Array(repeating: (true, 0.5), count: 11)).0.seated)    // 10 s
    }

    @Test func walkingThroughIsNotSitting() {
        // The centre keeps moving across the frame: never seated.
        let path = (0..<20).map { (true, 0.1 + Double($0) * 0.15) }
        #expect(!Self.seat(path).0.seated)
        // Seen in glimpses with long gaps: never seated.
        #expect(!Self.seat(Array(repeating: (true, 0.5), count: 6), every: FaceID.seatedGap + 1).0.seated)
    }

    @Test func seatedHoldsThroughMovementAndShortMisses_untilLeaveAfter() {
        var (s, t) = Self.seat(Array(repeating: (true, 0.5), count: 11))
        #expect(s.seated)
        s.observe(hit: true, center: (0.9, 0.5), now: t + 1)   // leaned over
        #expect(s.seated)
        s.observe(hit: false, center: nil, now: t + 60)
        #expect(s.seated)
        s.observe(hit: false, center: nil, now: t + 1 + CamPresence.leaveAfter)
        #expect(!s.seated && s.lastHit == nil)
    }

    // MARK: Identity (who + seated, with the frame rate it asks for)

    @Test func identityIdentifiesFastUntilSeatedAndKnown_withinTwoMinutes() {
        var id = CamIdentity()
        let frame = CamFrame(hit: true, light: 8, center: (0.5, 0.5))
        id.observe(frame, similarity: nil, now: Self.t0)
        #expect(id.identifying(now: Self.t0))
        for s in 1...10 { id.observe(frame, similarity: 0.7, now: Self.t0 + TimeInterval(s)) }
        #expect(id.seat.seated && id.who.who(now: Self.t0 + 10) == .mu)
        #expect(!id.identifying(now: Self.t0 + 10))
        // Never recognised (not enrolled): fast frames stop after the identify window.
        var stranger = CamIdentity()
        for s in 0...20 { stranger.observe(frame, similarity: nil, now: Self.t0 + TimeInterval(s)) }
        #expect(stranger.identifying(now: Self.t0 + 20))
        #expect(!stranger.identifying(now: Self.t0 + FaceID.identifyWindow))
    }

    @Test func darkOrGoneForgetsWhoAndSeat() {
        var id = CamIdentity()
        let frame = CamFrame(hit: true, light: 8, center: (0.5, 0.5))
        for s in 0...10 { id.observe(frame, similarity: 0.7, now: Self.t0 + TimeInterval(s)) }
        id.observe(CamFrame(hit: false, light: 0, dark: true), similarity: nil, now: Self.t0 + 11)
        #expect(!id.seat.seated && id.who.who(now: Self.t0 + 11) == .unknown && id.firstSeen == nil)
    }

    // MARK: 白加黑 active

    static func presence(pc: DeskPayload.Presence.Source?) -> DeskPayload.Presence {
        DeskPayload.Presence(present: true, source: "camera", idleS: nil, ageS: 1, staleAfterS: 60,
                             sources: pc.map { [DeskPayload.Presence.Source(source: "study", active: true, idleS: nil, ageS: 2, fresh: true), $0] })
    }

    @Test func pcActiveMeansTypedWithinThirtySeconds() {
        let t = Self.t0
        let typing = DeskPayload.Presence.Source(source: "pc", active: true, idleS: 3, ageS: 5, fresh: true)
        #expect(FaceID.pcActive(Self.presence(pc: typing), fetchedAt: t, now: t + 10))      // 18 s
        #expect(!FaceID.pcActive(Self.presence(pc: typing), fetchedAt: t, now: t + 25))     // 33 s
        let idle = DeskPayload.Presence.Source(source: "pc", active: true, idleS: 40, ageS: 1, fresh: true)
        #expect(!FaceID.pcActive(Self.presence(pc: idle), fetchedAt: t, now: t))
        let stale = DeskPayload.Presence.Source(source: "pc", active: true, idleS: 0, ageS: 0, fresh: false)
        #expect(!FaceID.pcActive(Self.presence(pc: stale), fetchedAt: t, now: t))
        let mac = DeskPayload.Presence.Source(source: "mac", active: true, idleS: 0, ageS: 0, fresh: true)
        #expect(!FaceID.pcActive(Self.presence(pc: mac), fetchedAt: t, now: t))            // only 白加黑
        #expect(!FaceID.pcActive(Self.presence(pc: nil), fetchedAt: t, now: t))
        #expect(!FaceID.pcActive(Self.presence(pc: typing), fetchedAt: nil, now: t))
    }

    @Test func decodesTheBoxPresenceSources() throws {
        let json = #"{"present":true,"source":"camera","idle_s":null,"age_s":1,"stale_after_s":60,"sources":[{"source":"pc","active":true,"idle_s":2,"age_s":4,"fresh":true,"received":"2026-11-01T00:00:00Z"}]}"#
        let p = try JSONDecoder().decode(DeskPayload.Presence.self, from: Data(json.utf8))
        #expect(p.sources?.first == DeskPayload.Presence.Source(source: "pc", active: true, idleS: 2, ageS: 4, fresh: true))
    }

    // MARK: Alignment

    @Test func alignmentRecoversAKnownSimilarityTransform() throws {
        // The reference points scaled ×2, turned 10°, shifted: the solver must undo exactly that.
        let angle = 10.0 * .pi / 180, scale = 2.0
        let truth = FaceAlign.Transform(a: scale * cos(angle), b: scale * sin(angle), tx: 30, ty: -12)
        let source = FaceAlign.reference
        let target = source.map(truth.apply)
        let t = try #require(FaceAlign.transform(from: source, to: target))
        #expect(abs(t.a - truth.a) < 1e-9 && abs(t.b - truth.b) < 1e-9)
        #expect(abs(t.tx - truth.tx) < 1e-9 && abs(t.ty - truth.ty) < 1e-9)
        #expect(FaceAlign.transform(from: [(1, 1), (1, 1)], to: [(0, 0), (2, 2)]) == nil)   // degenerate
        #expect(FaceAlign.referenceBottomLeft[0].y == FaceAlign.size - FaceAlign.reference[0].y)
    }
}
