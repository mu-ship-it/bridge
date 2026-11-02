import Foundation

/// Who is at the desk: Mu, someone else, or no confident answer. On-device only: Apple Vision
/// finds the face, `FaceEmbedder.mlmodel` (SFace / MobileFaceNet, OpenCV Zoo, Apache-2.0) turns
/// the aligned 112×112 crop into a 128-d embedding, and this file compares it with Mu's enrolled
/// template by cosine similarity. Pure, so matching, enrollment and the seated check are pinned
/// by tests; every threshold is here.
///
/// Privacy: only Mu is enrolled, and only as embeddings (never an image). An embedding that is not
/// taken into Mu's template is dropped as soon as it has been compared.
enum FaceID {
    // MARK: Matching (cosine similarity to Mu's template)

    /// At or above: Mu. SFace's own same-person threshold is 0.363; this is stricter, because a
    /// false "mu" switches the room on.
    static let matchSimilarity = 0.45
    /// Below: someone else. Between the two: `unknown`, never `other`.
    static let otherSimilarity = 0.20
    /// Agreeing confident reads in a row before a verdict changes (one odd frame decides nothing).
    static let verdictReads = 2
    /// A verdict is held this long after its last confirming read (side face, looking down).
    static let verdictHold: TimeInterval = 90

    // MARK: When a face is good enough to read

    /// Vision's face capture quality (0…1) at or above this.
    static let minQuality = 0.35
    /// The face box at least this wide, in camera pixels (the camera runs at 640×480).
    static let minFacePixels = 64.0
    /// Frontal: |yaw| and |pitch| under these (radians, ~20°), as CamPresence.lookYaw / lookPitch.
    static let maxYaw = 0.35
    static let maxPitch = 0.35

    // MARK: Enrollment (weak supervision: the person typing at 白加黑 is Mu)

    /// Mu's samples kept; the oldest goes when a new one comes in.
    static let samplesMax = 20
    /// Samples before the template is trusted at all (until then every read is `unknown`).
    static let samplesMin = 5
    /// 白加黑's keyboard / mouse active within this many seconds counts as "Mu is at his PC".
    static let pcActiveWithin: TimeInterval = 30
    /// The `/bridge/presence` source that is 白加黑.
    static let pcSource = "pc"
    /// While the template is filling: at most one sample this often (spread over many sittings).
    static let fillEvery: TimeInterval = 20
    /// Once full: one sample this often, folded in slowly (lighting, hair, glasses).
    static let refreshEvery: TimeInterval = 10 * 60
    /// Exponential moving average weight of a refresh sample in the template.
    static let refreshWeight = 0.05
    /// Once enrolled, a PC-active sample must already look like Mu this much (someone else at his PC
    /// must not teach the template).
    static let guardSimilarity = 0.36
    /// The hidden long-press ("enroll now"): a burst of samples, no PC needed, no guard.
    static let manualWindow: TimeInterval = 30
    static let manualEvery: TimeInterval = 1.5
    static let manualSamples = 10
    /// The hidden one-finger hold on the desk that starts it.
    static let enrollHold: TimeInterval = 3

    // MARK: Seated

    /// Face or upper body seen, steady, for this long: sat down.
    static let seatedAfter: TimeInterval = 10
    /// A gap between hits longer than this restarts the seated clock (frames come every second
    /// while identifying).
    static let seatedGap: TimeInterval = 4
    /// The head / body centre moving more than this (fraction of the frame) between hits: still walking.
    static let seatedDrift = 0.12
    /// While someone is there but not yet seated or not yet recognised: frames at the confirm rate,
    /// for at most this long after they first appeared.
    static let identifyWindow: TimeInterval = 2 * 60

    // MARK: Pure helpers

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return n > 0 ? v.map { Float(Double($0) / n) } : v
    }

    /// The face is worth embedding: frontal, sharp, big enough. Missing angles or quality: no.
    static func isReadable(yaw: Double?, pitch: Double?, quality: Double?, widthPixels: Double) -> Bool {
        guard let yaw, abs(yaw) < maxYaw, abs(pitch ?? 0) < maxPitch else { return false }
        guard let quality, quality >= minQuality else { return false }
        return widthPixels >= minFacePixels
    }

    /// One confident read, or nil (the grey band, or no template yet).
    static func verdict(similarity: Double?) -> Who? {
        guard let similarity else { return nil }
        if similarity >= matchSimilarity { return .mu }
        if similarity < otherSimilarity { return .other }
        return nil
    }

    /// 白加黑 was typed on within `pcActiveWithin`: its report's idle time plus the report's age plus
    /// the desk payload's own age.
    static func pcActive(_ presence: DeskPayload.Presence?, fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt, let pc = presence?.sources?.first(where: { $0.source == pcSource }),
              pc.active == true, pc.fresh != false else { return false }
        let since = Double((pc.idleS ?? 0) + (pc.ageS ?? 0)) + now.timeIntervalSince(fetchedAt)
        return since <= pcActiveWithin
    }
}

enum Who: String, Sendable, Equatable, Codable { case mu, other, unknown }

/// What DeskCamera hands over about the largest face: its embedding, only when it was readable.
struct FaceRead: Equatable, Sendable {
    var embedding: [Float]
    var quality: Double
}

/// Mu's template: up to `samplesMax` embeddings, their mean (unit length), and how tightly they
/// agree. Stored as embeddings only (FaceStore), never an image.
struct FaceEnrollment: Codable, Equatable, Sendable {
    private(set) var samples: [[Float]] = []
    private(set) var template: [Float] = []
    /// Mean of 1 − cosine(sample, template): 0 = every sample identical.
    private(set) var spread = 0.0
    private(set) var lastSample: Date?
    /// The hidden long-press burst, while it runs (not stored).
    private(set) var manualUntil: Date?
    private(set) var manualTaken = 0

    enum CodingKeys: String, CodingKey { case samples, template, spread, lastSample }

    var isEnrolled: Bool { samples.count >= FaceID.samplesMin }
    var isFull: Bool { samples.count >= FaceID.samplesMax }

    /// Cosine similarity to the template; nil until enrolled.
    func similarity(_ embedding: [Float]) -> Double? {
        isEnrolled ? FaceID.cosine(embedding, template) : nil
    }

    func isManual(now: Date) -> Bool { manualUntil.map { now < $0 } ?? false }

    /// The hidden long-press: take the next `manualSamples` readable faces as Mu's.
    mutating func startManual(now: Date) {
        manualUntil = now + FaceID.manualWindow
        manualTaken = 0
        lastSample = nil
    }

    /// Offers a readable face; true when it was taken into Mu's template (the caller saves).
    /// Taken only during the long-press burst, or while 白加黑 is being typed on.
    mutating func offer(_ read: FaceRead, pcActive: Bool, now: Date) -> Bool {
        let embedding = FaceID.normalized(read.embedding)
        if isManual(now: now) {
            if let lastSample, now.timeIntervalSince(lastSample) < FaceID.manualEvery { return false }
            append(embedding, now: now)
            template = mean(samples)
            manualTaken += 1
            if manualTaken >= FaceID.manualSamples { manualUntil = nil }
            recomputeSpread()
            return true
        }
        guard pcActive else { return false }
        let every = isFull ? FaceID.refreshEvery : FaceID.fillEvery
        if let lastSample, now.timeIntervalSince(lastSample) < every { return false }
        let like = FaceID.cosine(embedding, template)
        if isEnrolled {
            guard like >= FaceID.guardSimilarity else { return false }
        } else if !samples.isEmpty, like < FaceID.guardSimilarity {
            // Filling, and this face disagrees with what is there: start over from it. Mu types at
            // his own PC far more often than anyone else, so the set settles on him.
            samples = []
        }
        if isFull {
            append(embedding, now: now)
            let w = Float(FaceID.refreshWeight)
            template = FaceID.normalized(zip(template, embedding).map { (1 - w) * $0 + w * $1 })
        } else {
            append(embedding, now: now)
            template = mean(samples)
        }
        recomputeSpread()
        return true
    }

    /// Forget Mu entirely.
    mutating func clear() { self = FaceEnrollment() }

    private mutating func append(_ embedding: [Float], now: Date) {
        samples.append(embedding)
        if samples.count > FaceID.samplesMax { samples.removeFirst(samples.count - FaceID.samplesMax) }
        lastSample = now
    }

    private mutating func recomputeSpread() {
        spread = samples.isEmpty ? 0 : samples.map { 1 - FaceID.cosine($0, template) }.reduce(0, +) / Double(samples.count)
    }

    private func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Double](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in v.indices { sum[i] += Double(v[i]) } }
        return FaceID.normalized(sum.map { Float($0 / Double(vectors.count)) })
    }
}

/// Mu / other / unknown over time: `verdictReads` agreeing confident reads to decide, held
/// `verdictHold` after the last confirming one. A side face or a dim frame reads nothing, so it
/// never flips the verdict and never makes anyone `other`.
struct WhoTracker: Equatable, Sendable {
    private(set) var verdict = Who.unknown
    private(set) var confirmedAt: Date?
    /// The latest similarity seen (any band), for the report; nil when none since the reset.
    private(set) var score: Double?
    private var streak: (who: Who, count: Int)?

    static func == (l: WhoTracker, r: WhoTracker) -> Bool {
        l.verdict == r.verdict && l.confirmedAt == r.confirmedAt && l.score == r.score
            && l.streak?.who == r.streak?.who && l.streak?.count == r.streak?.count
    }

    /// `similarity`: a readable face compared with an enrolled template; nil = nothing to read.
    mutating func observe(similarity: Double?, now: Date) {
        guard let similarity else { return }
        score = similarity
        guard let read = FaceID.verdict(similarity: similarity) else { return }
        let count = streak?.who == read ? (streak?.count ?? 0) + 1 : 1
        streak = (read, count)
        if read == verdict || count >= FaceID.verdictReads {
            verdict = read
            confirmedAt = now
        }
    }

    func who(now: Date) -> Who {
        guard let confirmedAt, now.timeIntervalSince(confirmedAt) < FaceID.verdictHold else { return .unknown }
        return verdict
    }

    mutating func reset() { self = WhoTracker() }
}

/// Sat down: a face or an upper body seen without a gap longer than `seatedGap` and without its
/// centre jumping more than `seatedDrift`, for `seatedAfter`. Once seated, moving around does not
/// unseat; only `CamPresence.leaveAfter` without any hit does.
struct SeatTracker: Equatable, Sendable {
    private(set) var since: Date?
    private(set) var lastHit: Date?
    private(set) var center: (x: Double, y: Double)?
    private(set) var seated = false

    static func == (l: SeatTracker, r: SeatTracker) -> Bool {
        l.since == r.since && l.lastHit == r.lastHit && l.seated == r.seated
            && l.center?.x == r.center?.x && l.center?.y == r.center?.y
    }

    /// `center`: the face (else upper body) centre, as a fraction of the frame.
    mutating func observe(hit: Bool, center: (x: Double, y: Double)?, now: Date) {
        guard hit else {
            if let lastHit, now.timeIntervalSince(lastHit) >= (seated ? CamPresence.leaveAfter : FaceID.seatedGap) {
                self = SeatTracker()
            }
            return
        }
        defer { lastHit = now; self.center = center ?? self.center }
        if seated { return }
        let gap = lastHit.map { now.timeIntervalSince($0) > FaceID.seatedGap } ?? true
        let moved: Bool = {
            guard let center, let old = self.center else { return false }
            return max(abs(center.x - old.x), abs(center.y - old.y)) > FaceID.seatedDrift
        }()
        if since == nil || gap || moved { since = now }
        if let since, now.timeIntervalSince(since) >= FaceID.seatedAfter { seated = true }
    }

    mutating func reset() { self = SeatTracker() }
}

/// The camera's identity half, next to CamDetector: who it is and whether they sat down.
struct CamIdentity: Equatable, Sendable {
    private(set) var who = WhoTracker()
    private(set) var seat = SeatTracker()
    /// When someone was first seen since the last reset (bounds the fast identifying frames).
    private(set) var firstSeen: Date?

    mutating func observe(_ frame: CamFrame, similarity: Double?, now: Date) {
        if frame.dark { reset(); return }
        seat.observe(hit: frame.hit, center: frame.center, now: now)
        if seat.lastHit == nil { reset(); return }   // gone (the seat tracker forgot them)
        if frame.hit, firstSeen == nil { firstSeen = now }
        who.observe(similarity: similarity, now: now)
    }

    /// Someone there but not yet seated or not yet recognised, within `identifyWindow`: the camera
    /// keeps its one-a-second rate.
    func identifying(now: Date) -> Bool {
        guard let firstSeen, now.timeIntervalSince(firstSeen) < FaceID.identifyWindow else { return false }
        return !seat.seated || who.who(now: now) == .unknown
    }

    mutating func reset() { self = CamIdentity() }
}

/// Mu's enrollment on disk: Application Support, complete file protection, out of backups.
/// Embeddings only.
enum FaceStore {
    static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("face-enrollment.json")
    }

    static func load() -> FaceEnrollment {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(FaceEnrollment.self, from: data) else { return FaceEnrollment() }
        return saved
    }

    static func save(_ enrollment: FaceEnrollment) {
        guard var url, let data = try? JSONEncoder().encode(enrollment) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // Kept in memory; the next accepted sample tries again.
        }
    }
}

/// The ArcFace / SFace alignment: a similarity transform (scale, rotation, shift; no shear) taking
/// the five landmarks found by Vision onto the model's 112×112 reference points.
enum FaceAlign {
    static let size = 112.0
    /// Reference points, top-left origin: eye, eye, nose tip, mouth corner, mouth corner (left to right in the image).
    static let reference: [(x: Double, y: Double)] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]

    /// x' = a·x − b·y + tx, y' = b·x + a·y + ty.
    struct Transform: Equatable, Sendable {
        var a, b, tx, ty: Double
        func apply(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
            (a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
        }
    }

    /// Least-squares similarity transform from `source` to `target` (same count, ≥ 2 points).
    static func transform(from source: [(x: Double, y: Double)], to target: [(x: Double, y: Double)]) -> Transform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let sx = source.map(\.x).reduce(0, +) / n, sy = source.map(\.y).reduce(0, +) / n
        let tx = target.map(\.x).reduce(0, +) / n, ty = target.map(\.y).reduce(0, +) / n
        var num1 = 0.0, num2 = 0.0, den = 0.0
        for (p, q) in zip(source, target) {
            let px = p.x - sx, py = p.y - sy, qx = q.x - tx, qy = q.y - ty
            num1 += px * qx + py * qy
            num2 += px * qy - py * qx
            den += px * px + py * py
        }
        guard den > 0 else { return nil }
        let a = num1 / den, b = num2 / den
        return Transform(a: a, b: b, tx: tx - (a * sx - b * sy), ty: ty - (b * sx + a * sy))
    }

    /// The reference points with a bottom-left origin (Core Image, Vision).
    static var referenceBottomLeft: [(x: Double, y: Double)] { reference.map { ($0.x, size - $0.y) } }
}
