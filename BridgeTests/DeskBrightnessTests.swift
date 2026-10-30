import Foundation
import Testing
@testable import Bridge

@Suite struct DeskBrightnessTests {
    static var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 2026-10-27 at `hour`:`minute` in Shanghai.
    static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        shanghai.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute))!
    }

    static func presence(_ present: Bool, age: Int) -> DeskPayload.Presence {
        DeskPayload.Presence(present: present, source: "pc", idleS: 3, ageS: age, staleAfterS: 90)
    }

    @Test func presentIsFreshAndActive() {
        let fetched = Self.at(10)
        #expect(BrightnessPolicy.isPresent(Self.presence(true, age: 10), fetchedAt: fetched, now: fetched))
        #expect(BrightnessPolicy.isPresent(Self.presence(true, age: 10), fetchedAt: fetched, now: fetched + 80))
        // Report age at fetch plus time since the fetch past 90 s: away.
        #expect(!BrightnessPolicy.isPresent(Self.presence(true, age: 10), fetchedAt: fetched, now: fetched + 81))
        #expect(!BrightnessPolicy.isPresent(Self.presence(false, age: 1), fetchedAt: fetched, now: fetched))
        #expect(!BrightnessPolicy.isPresent(nil, fetchedAt: fetched, now: fetched))
        #expect(!BrightnessPolicy.isPresent(Self.presence(true, age: 1), fetchedAt: nil, now: fetched))
    }

    @Test func daytimeLevels() {
        let noon = Self.at(12)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: noon, calendar: Self.shanghai) == 0.85)
        #expect(BrightnessPolicy.level(present: false, lastArrival: nil, now: noon, calendar: Self.shanghai) == 0.10)
    }

    @Test func nightPresentIsHalf_andAwayStaysDimNeverZero() {
        for (h, m) in [(23, 0), (2, 30), (6, 59)] {
            let t = Self.at(h, m)
            #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: t, calendar: Self.shanghai) == 0.5)
            #expect(BrightnessPolicy.level(present: false, lastArrival: nil, now: t, calendar: Self.shanghai) == 0.10)
        }
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: Self.at(7), calendar: Self.shanghai) == 0.85)
        #expect(BrightnessPolicy.level(present: true, lastArrival: nil, now: Self.at(22, 59), calendar: Self.shanghai) == 0.85)
        #expect(BrightnessPolicy.away > 0)
    }

    static func away(_ awayS: Int?) -> DeskPayload.Presence {
        DeskPayload.Presence(present: false, source: "study", idleS: nil, ageS: 5, staleAfterS: 180,
                             awayS: awayS, awayAfterS: 600)
    }

    @Test func awayTenMinutesGoesFullyBlack() {
        let fetched = Self.at(10)
        #expect(!BrightnessPolicy.isLightsOut(Self.away(0), fetchedAt: fetched, now: fetched))
        #expect(!BrightnessPolicy.isLightsOut(Self.away(590), fetchedAt: fetched, now: fetched + 9.9))
        // The box's away_s at fetch plus the time since reaches away_after_s.
        #expect(BrightnessPolicy.isLightsOut(Self.away(590), fetchedAt: fetched, now: fetched + 10))
        #expect(BrightnessPolicy.isLightsOut(Self.away(900), fetchedAt: fetched, now: fetched))
        // Present, an old box without away_s, or no fetch yet: never black.
        #expect(!BrightnessPolicy.isLightsOut(Self.presence(true, age: 1), fetchedAt: fetched, now: fetched + 3600))
        #expect(!BrightnessPolicy.isLightsOut(Self.away(nil), fetchedAt: fetched, now: fetched + 3600))
        #expect(!BrightnessPolicy.isLightsOut(Self.away(900), fetchedAt: nil, now: fetched))
        // The camera seeing him ends it at once; absent / dark / unknown leave it to the box.
        #expect(!BrightnessPolicy.isLightsOut(camera: .looking, Self.away(900), fetchedAt: fetched, now: fetched))
        #expect(!BrightnessPolicy.isLightsOut(camera: .present, Self.away(900), fetchedAt: fetched, now: fetched))
        #expect(BrightnessPolicy.isLightsOut(camera: .absent, Self.away(900), fetchedAt: fetched, now: fetched))
        #expect(BrightnessPolicy.isLightsOut(camera: .dark, Self.away(900), fetchedAt: fetched, now: fetched))
        // Lights-out beats everything, even a new item's 30 s and Mu at the desk at noon.
        let noon = Self.at(12)
        #expect(BrightnessPolicy.level(present: false, lastArrival: noon, now: noon + 1, calendar: Self.shanghai,
                                       lightsOut: true) == 0)
        #expect(BrightnessPolicy.lightsOut == 0)
    }

    @Test func aNewItemLightsTheScreenFor30sEvenWhenAway() {
        let arrived = Self.at(15)
        func level(_ after: TimeInterval) -> CGFloat {
            BrightnessPolicy.level(present: false, lastArrival: arrived, now: arrived + after, calendar: Self.shanghai)
        }
        #expect(level(0) == 0.85)
        #expect(level(29.9) == 0.85)
        #expect(level(30) == 0.10)
        // At night the forced level is the night level.
        let late = Self.at(23, 30)
        #expect(BrightnessPolicy.level(present: false, lastArrival: late, now: late + 5, calendar: Self.shanghai) == 0.5)
    }
}
