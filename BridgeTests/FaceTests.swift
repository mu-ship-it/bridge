import Testing
import Foundation
@testable import Bridge

struct FaceTests {
    private func mood(_ edit: (inout FaceInput) -> Void = { _ in }) -> Mood {
        var input = FaceInput()
        edit(&input)
        return Face.mood(input)
    }

    @Test func eachRuleGivesItsFace() {
        #expect(mood() == .calm && Mood.calm.face == "(•‿•)")
        #expect(mood { $0.blink = true } == .blink && Mood.blink.face == "(-‿-)")
        #expect(mood { $0.lanes = 2 } == .busy && Mood.busy.face == "(⌐■_■)")
        #expect(mood { $0.attention = 1 } == .alarmed && Mood.alarmed.face == "(°□°)")
        #expect(mood { $0.failed = true } == .stern && Mood.stern.face == "(ಠ_ಠ)")
        #expect(mood { $0.topSeat = 90 } == .stern)
        #expect(mood { $0.topSeat = 89 } == .calm)
        #expect(mood { $0.awayFor = 120 } == .asleep && Mood.asleep.face == "(-_-)" && Mood.asleep.suffix == "zZ")
        #expect(mood { $0.awayFor = 119 } == .calm)
        #expect(mood { $0.glance = true } == .sideEye && Mood.sideEye.face == "(¬_¬)")
        #expect(Mood.allCases.allSatisfy { $0.face.count >= 5 && $0.face.count <= 9 })
    }

    @Test func precedenceIsFailedAttentionLanesAwayGlanceIdle() {
        let everything = FaceInput(failed: true, topSeat: 95, attention: 3, lanes: 2, awayFor: 600, glance: true, blink: true)
        #expect(Face.mood(everything) == .stern)
        var i = everything; i.failed = false; i.topSeat = 10
        #expect(Face.mood(i) == .alarmed)
        i.attention = 0
        #expect(Face.mood(i) == .busy)
        i.lanes = 0
        #expect(Face.mood(i) == .asleep)
        i.awayFor = 0
        #expect(Face.mood(i) == .sideEye)
        i.glance = false
        #expect(Face.mood(i) == .blink)
        i.blink = false
        #expect(Face.mood(i) == .calm)
    }

    @Test func theInputComesFromThePayload() {
        let note = DeskPayload.Item(id: "a", kind: "note", text: "x", ts: "")
        let running = DeskPayload.Item(id: "b", kind: "progress", text: "", ts: "",
                                       progress: .init(done: 1, total: 2, pct: 50, eta: nil, note: nil, state: "running"))
        let failed = DeskPayload.Item(id: "c", kind: "progress", text: "", ts: "",
                                      progress: .init(done: 1, total: 2, pct: 50, eta: nil, note: nil, state: "failed"))
        let seats = [DeskPayload.Seat(name: "Max", pct: 62), DeskPayload.Seat(name: "Team", pct: 97)]
        #expect(Face.input(attention: [running], seats: [], lanes: 0) == FaceInput())     // progress is not attention
        #expect(Face.input(attention: [note, running], seats: [], lanes: 1).attention == 1)
        #expect(Face.input(attention: [failed], seats: [], lanes: 0).failed)
        #expect(Face.input(attention: [], seats: seats, lanes: 0).topSeat == 97)
    }

    private func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c.date(from: DateComponents(timeZone: .gmt, year: 2026, month: 10, day: 28, hour: h, minute: m, second: s))!
    }

    @Test func theNightGlanceIsFiveSecondsAtTheHalfHourOnlyAtNightAndOnlyWhenPresent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        func on(_ d: Date, present: Bool = true) -> Bool { NightGlance.isActive(now: d, present: present, calendar: cal) }
        #expect(on(date(23, 30, 0)) && on(date(23, 30, 4)))
        #expect(!on(date(23, 30, 5)))
        #expect(!on(date(23, 29, 59)))
        #expect(on(date(0, 30, 1)) && on(date(4, 30, 2)))
        #expect(!on(date(5, 30, 1)) && !on(date(12, 30, 1)) && !on(date(22, 30, 1)))
        #expect(!on(date(23, 30, 1), present: false))
    }

    @Test func awayStartsWhenPresenceGoesAndResetsWhenItReturns() {
        var away = AwayTracker()
        let t0 = date(10, 0, 0)
        away.update(present: true, now: t0)
        #expect(away.awayFor(now: t0.addingTimeInterval(500)) == 0)
        away.update(present: false, now: t0.addingTimeInterval(10))
        away.update(present: false, now: t0.addingTimeInterval(60))        // does not restart
        #expect(away.awayFor(now: t0.addingTimeInterval(130)) == 120)
        away.update(present: true, now: t0.addingTimeInterval(140))
        #expect(away.awayFor(now: t0.addingTimeInterval(150)) == 0)
    }

    @Test func aNodHappensOnlyWhenAKnownLaneCrossesATenPercentMark() {
        #expect(ProgressMarks.mark(0.09) == 0 && ProgressMarks.mark(0.1) == 1 && ProgressMarks.mark(1.4) == 10)
        let first = ProgressMarks.crossings(old: [:], lanes: [("a", 0.35)])
        #expect(first.marks == ["a": 3] && !first.crossed)                       // first sight only records
        #expect(!ProgressMarks.crossings(old: first.marks, lanes: [("a", 0.39)]).crossed)
        #expect(ProgressMarks.crossings(old: first.marks, lanes: [("a", 0.41)]).crossed)
        #expect(!ProgressMarks.crossings(old: first.marks, lanes: [("a", 0.2)]).crossed)   // going back is no nod
    }

    @Test func aFinishedLaneStaysFullBeforeItCollapses() {
        func lane(_ name: String, _ bar: Double) -> MusterTile.Lane {
            MusterTile.Lane(row: Board.Row(label: name, bar: bar), host: nil)
        }
        let gone = LaneDeparture.finished(old: [lane("a", 0.4), lane("b", 1)], new: [lane("b", 1)])
        #expect(gone.map(\.id) == ["a"] && gone[0].row.fill == 1)
        #expect(LaneDeparture.wait(previous: lane("a", 0.4)) == .milliseconds(1200))
        #expect(LaneDeparture.wait(previous: lane("a", 1)) == .milliseconds(600))
    }

    @Test func theFaceFitsTheStripInPortraitAndLandscape() {
        for size in [CGSize(width: 375, height: 812), CGSize(width: 402, height: 874),
                     CGSize(width: 812, height: 375), CGSize(width: 874, height: 402)] {
            let m = DeskMetrics.make(size: size)
            let room = m.clocksRoom(screenWidth: size.width)
            #expect(m.faceWidth <= 8 * 26 * 0.6 + 0.001)
            #expect(room >= m.clocksWidth, "\(size)")
        }
    }
}

extension Mood: CaseIterable {
    public static var allCases: [Mood] { [.calm, .blink, .busy, .alarmed, .stern, .asleep, .sideEye] }
}
