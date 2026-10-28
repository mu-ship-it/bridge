import Foundation

/// The desk's face: five to nine ASCII characters whose mood is a pure function of what the desk
/// shows. `Face.rules` is the one table; the first rule that holds wins, so its order is the precedence.
enum Mood: Equatable, Sendable {
    case calm, blink, busy, alarmed, stern, asleep, sideEye

    /// The face itself.
    var face: String {
        switch self {
        case .calm: "(•‿•)"
        case .blink: "(-‿-)"
        case .busy: "(⌐■_■)"
        case .alarmed: "(°□°)"
        case .stern: "(ಠ_ಠ)"
        case .asleep: "(-_-)"
        case .sideEye: "(¬_¬)"
        }
    }

    /// Only the sleeper carries text beside the face; the view fades it in and out.
    var suffix: String? { self == .asleep ? "zZ" : nil }
}

/// Everything the mood depends on, already reduced to plain values.
struct FaceInput: Equatable, Sendable {
    /// A progress row in the `failed` state.
    var failed = false
    /// The highest seat percentage on the top line.
    var topSeat = 0
    /// Attention items that are notes (progress rows do not count).
    var attention = 0
    var lanes = 0
    /// How long Mu has been away; 0 while present.
    var awayFor: TimeInterval = 0
    /// Inside the 5 s night glance (it already requires Mu to be present).
    var glance = false
    /// The 120 ms blink, switched by the view's own timer.
    var blink = false
}

enum Face {
    static let awayAfter: TimeInterval = 120

    /// Precedence, top to bottom: failed/seat > attention > lanes > away > night glance > idle.
    static let rules: [(mood: @Sendable (FaceInput) -> Mood, when: @Sendable (FaceInput) -> Bool)] = [
        ({ _ in .stern }, { $0.failed || $0.topSeat >= SeatsLine.redFrom }),
        ({ _ in .alarmed }, { $0.attention > 0 }),
        ({ _ in .busy }, { $0.lanes > 0 }),
        ({ _ in .asleep }, { $0.awayFor >= awayAfter }),
        ({ _ in .sideEye }, { $0.glance }),
        ({ $0.blink ? .blink : .calm }, { _ in true }),
    ]

    static func mood(_ input: FaceInput) -> Mood {
        rules.first { $0.when(input) }!.mood(input)
    }

    /// The input a desk payload gives (everything but time-based parts, which the caller adds).
    static func input(attention: [DeskPayload.Item], seats: [DeskPayload.Seat], lanes: Int) -> FaceInput {
        FaceInput(failed: attention.contains { $0.progress?.isFailed == true },
                  topSeat: seats.map(\.pct).max() ?? 0,
                  attention: attention.filter { $0.progress == nil }.count,
                  lanes: lanes)
    }
}

/// The night glance: 23:30–05:00 with Mu present, at the half hour for 5 s. Pure in `now`,
/// so there is nothing to remember between ticks and nothing random.
enum NightGlance {
    static let duration = 5

    static func isActive(now: Date, present: Bool, calendar: Calendar = .current) -> Bool {
        guard present else { return false }
        let c = calendar.dateComponents([.hour, .minute, .second], from: now)
        let (h, m, s) = (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let night = (h == 23 && m >= 30) || h < 5
        return night && m == 30 && s < duration
    }
}

/// How long Mu has been away: starts when presence first reads inactive, resets when it returns.
struct AwayTracker: Equatable, Sendable {
    private(set) var since: Date?

    mutating func update(present: Bool, now: Date) {
        if present { since = nil } else if since == nil { since = now }
    }

    func awayFor(now: Date) -> TimeInterval { since.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
}

/// A lane's bar crossing a 10 % mark is a nod.
enum ProgressMarks {
    static func mark(_ fill: Double) -> Int { Int((min(max(fill, 0), 1) * 10).rounded(.down)) }

    /// New marks per lane, and whether any known lane's mark went up. A lane seen for the first time only records.
    static func crossings(old: [String: Int], lanes: [(id: String, fill: Double)]) -> (marks: [String: Int], crossed: Bool) {
        var marks: [String: Int] = [:]
        var crossed = false
        for lane in lanes {
            let now = mark(lane.fill)
            marks[lane.id] = now
            if let before = old[lane.id], now > before { crossed = true }
        }
        return (marks, crossed)
    }
}

/// Lanes that left the board: they are shown full for a moment before their row collapses.
enum LaneDeparture {
    static let hold: Duration = .milliseconds(600)
    static let fill: Duration = .milliseconds(600)

    /// Lanes in `old` that are not in `new`, drawn at 100 %.
    static func finished(old: [MusterTile.Lane], new: [MusterTile.Lane]) -> [MusterTile.Lane] {
        let live = Set(new.map(\.id))
        return old.filter { !live.contains($0.id) }.map { lane in
            var row = lane.row
            row.bar = 1
            return MusterTile.Lane(row: row, host: lane.host)
        }
    }

    /// How long to keep a finished lane: the bar's own fill time first when it was not full yet.
    static func wait(previous: MusterTile.Lane?) -> Duration {
        (previous?.row.fill ?? 0) >= 1 ? hold : fill + hold
    }
}
