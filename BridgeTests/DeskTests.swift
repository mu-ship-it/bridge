import Foundation
import Testing
@testable import Bridge

@Suite struct DeskTests {
    /// The shape docs/API.md shows for GET /bridge/board/desk.
    static let full = """
    {"time": {"now": "2026-10-27T09:00:00Z", "tz": "Asia/Shanghai", "utc_offset_s": 28800},
     "weather": {"temp_c": 6.4, "feels_c": 3.9, "humidity": 61, "wind_kmh": 12.2, "code": 3, "is_day": true,
                 "high_c": 9.1, "low_c": -1.5, "precip_pct": 10, "place": "Shenyang", "lat": 41.8, "lon": 123.43,
                 "fetched_at": "2026-10-27T08:52:10Z", "age_s": 470, "stale": false},
     "attention": [{"id": "e_01", "kind": "alert", "title": null, "text": "Backup failed", "level": "warn",
                    "ts": "2026-10-27T08:58:00Z", "speak": true, "source": "event"},
                   {"id": "b_muster_abc", "kind": "board.stalled", "title": "Lanes · teal", "text": "no output",
                    "level": "info", "ts": "2026-10-27T08:45:00Z", "speak": false, "source": "board:muster"}],
     "presence": {"present": true, "source": "pc", "active": true, "idle_s": 4, "age_s": 12,
                  "stale_after_s": 90, "sources": []}}
    """

    @Test func decodesTheFullPayload() throws {
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(Self.full.utf8))
        #expect(p.time?.tz == "Asia/Shanghai" && p.time?.utcOffsetS == 28_800)
        #expect(p.weather?.tempC == 6.4 && p.weather?.code == 3 && p.weather?.place == "Shenyang")
        #expect(p.attention.map(\.id) == ["e_01", "b_muster_abc"])
        #expect(p.attention[0].speak && p.attention[0].isWarning && p.attention[0].title == nil)
        #expect(!p.attention[1].isWarning && p.attention[1].title == "Lanes · teal")
        #expect(p.presence?.present == true && p.presence?.ageS == 12 && p.presence?.staleAfterS == 90)
    }

    @Test func decodesAThinPayload() throws {
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(#"{"weather": null, "attention": [{"id": "x", "kind": "notify"}]}"#.utf8))
        #expect(p.weather == nil && p.time == nil && p.presence == nil)
        #expect(p.attention == [DeskPayload.Item(id: "x", kind: "notify", text: "", ts: "")])
    }

    @Test func climateTileShowsDashesWhenUnavailable() {
        let none = ClimateTile(celsius: nil, humidity: nil, sensor: nil)
        #expect(none.temperature == "—" && none.humidity == "—")
        let some = ClimateTile(celsius: 21.46, humidity: 38.6, sensor: "HomePod mini")
        #expect(some.temperature == "21.5°" && some.humidity == "39%" && some.sensor == "HomePod mini")
        #expect(ClimateTile(celsius: 20, humidity: nil, sensor: nil).humidity == "—")
    }

    @Test func weatherTileRoundsAndNamesTheSky() {
        let p = try? JSONDecoder().decode(DeskPayload.self, from: Data(Self.full.utf8))
        let tile = WeatherTile(p?.weather)
        #expect(tile.temperature == "6°" && tile.range == "-2° / 9°")
        #expect(tile.summary == "Overcast" && tile.symbol == "cloud.fill" && tile.place == "Shenyang" && !tile.stale)

        let missing = WeatherTile(nil)
        #expect(missing.temperature == "—" && missing.range == "—" && missing.stale)
        #expect(WeatherTile.describe(code: 0, isDay: false).1 == "moon.stars.fill")
        #expect(WeatherTile.describe(code: 73, isDay: true).0 == "Snow")
        #expect(WeatherTile.describe(code: nil, isDay: true).0 == "Weather")
    }

    @Test func onlyItemsNotSeenBeforeAreNew_andTheFirstFetchIsSilent() {
        let a = DeskPayload.Item(id: "a", kind: "notify", text: "A", ts: "")
        let b = DeskPayload.Item(id: "b", kind: "alert", text: "B", level: "warn", ts: "")
        #expect(AttentionDiff.newItems([a, b], seen: nil).isEmpty)
        #expect(AttentionDiff.newItems([a, b], seen: ["a"]) == [b])
        #expect(AttentionDiff.newItems([a], seen: ["a", "b"]).isEmpty)
    }

    @Test func theAckIsAnAttentionAckEventNamingTheIds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = DeskAck.event(ids: ["e_01"], now: now)
        #expect(event.type == "attention.ack" && event.ts == ISO.string(now) && !event.note.isEmpty)
        #expect(event.payload == .object(["ids": .array([.string("e_01")])]))
    }

    @Test func theSensorIsPickedByAccessoryThenRoom() {
        typealias C = ClimateSensorPick.Candidate
        let all = [
            C(name: "Strip", room: "Study", hasTemperature: false, hasHumidity: false),
            C(name: "Eve Room", room: "Bedroom", hasTemperature: true, hasHumidity: false),
            C(name: "HomePod mini", room: "Study", hasTemperature: true, hasHumidity: true),
        ]
        #expect(ClimateSensorPick.pick(all, wanted: "") == 2)            // both readings win
        #expect(ClimateSensorPick.pick(all, wanted: "eve room") == 1)
        #expect(ClimateSensorPick.pick(all, wanted: "STUDY") == 2)       // the strip has no sensor
        #expect(ClimateSensorPick.pick(all, wanted: "Kitchen") == nil)
        #expect(ClimateSensorPick.pick([all[0]], wanted: "") == nil)
    }

    @Test func theDeskRequestAsksForThePhonesTimeZone() throws {
        let config = BridgeConfig(baseURL: URL(string: "https://box.example")!, token: "t", deviceId: "desk-mini")
        let r = BoxClient(config: config).deskRequest(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(r.url?.path() == "/bridge/board/desk")
        #expect(r.url?.query()?.contains("tz=Asia/Shanghai") == true)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func attentionIsAThinStripWhenEmptyAndGrowsToFitUpToTheCap() {
        let screen: CGFloat = 800
        #expect(AttentionSizing.height(items: 0, screen: screen) == AttentionSizing.strip)
        let one = AttentionSizing.height(items: 1, screen: screen)
        let two = AttentionSizing.height(items: 2, screen: screen)
        #expect(one > AttentionSizing.strip && two > one)
        #expect(AttentionSizing.height(items: 50, screen: screen) == screen * AttentionSizing.maxShare)
        // A short landscape screen never goes below the strip.
        #expect(AttentionSizing.height(items: 1, screen: 60) == AttentionSizing.strip)
    }

    @Test func theLayoutShiftsEveryThreeMinutesWithinSixPoints() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LayoutShift.slot(at: t) == LayoutShift.slot(at: t.addingTimeInterval(1)))
        let next = LayoutShift.nextChange(after: t)
        #expect(next > t && next.timeIntervalSince(t) <= 180)
        #expect(LayoutShift.slot(at: next) == LayoutShift.slot(at: t) + 1)
        #expect(LayoutShift.slot(at: next.addingTimeInterval(-0.001)) == LayoutShift.slot(at: t))
        var seen = Set<[Int]>()
        for slot in 0..<500 {
            let o = LayoutShift.offset(slot: slot)
            #expect(abs(o.x) <= 6 && abs(o.y) <= 6)
            #expect(o == LayoutShift.offset(slot: slot))
            seen.insert([o.x, o.y])
        }
        #expect(seen.count > 50)
    }
}
