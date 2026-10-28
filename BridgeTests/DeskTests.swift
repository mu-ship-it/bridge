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

    @Test func theRoomTilePrefersAFreshBoxReading() {
        let homeKit = ClimateTile(celsius: 20, humidity: 40, sensor: "HomePod mini")
        let fresh = DeskPayload.Room(tempC: 23.4, humidity: 47, source: "study", ageS: 30)
        let tile = ClimateSourcePolicy.choose(server: fresh, homeKit: homeKit)
        #expect(tile.temperature == "23.4°" && tile.humidity == "47%" && tile.sensor == "study · HA")
    }

    @Test func theRoomTileFallsBackToHomeKitWhenTheBoxHasNoneOrIsStale() {
        let homeKit = ClimateTile(celsius: 20, humidity: 40, sensor: "HomePod mini")
        let stale = DeskPayload.Room(tempC: 23.4, humidity: 47, source: "study", ageS: 1_200, stale: true)
        #expect(ClimateSourcePolicy.choose(server: nil, homeKit: homeKit) == homeKit)
        #expect(ClimateSourcePolicy.choose(server: DeskPayload.Room(), homeKit: homeKit) == homeKit)
        #expect(ClimateSourcePolicy.choose(server: stale, homeKit: homeKit) == homeKit)
    }

    @Test func aStaleBoxReadingBeatsNothing() {
        let none = ClimateTile(celsius: nil, humidity: nil, sensor: nil)
        let stale = DeskPayload.Room(tempC: 23.4, humidity: nil, source: "study", ageS: 1_200, stale: true)
        let tile = ClimateSourcePolicy.choose(server: stale, homeKit: none)
        #expect(tile.temperature == "23.4°" && tile.humidity == "—" && tile.sensor == "study · HA · 20m")
        #expect(ClimateSourcePolicy.choose(server: nil, homeKit: none) == none)
    }

    @Test func decodesTheRoomObject() throws {
        let json = #"{"room": {"temp_c": 23.4, "humidity": null, "source": "study", "age_s": 12, "stale": false}}"#
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(json.utf8))
        #expect(p.room?.tempC == 23.4 && p.room?.humidity == nil && p.room?.source == "study")
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

    @Test func deskMetricsFillTheScreenOnABigAndASmallPhone() {
        for size in [CGSize(width: 812, height: 375), CGSize(width: 874, height: 402),
                     CGSize(width: 375, height: 812), CGSize(width: 402, height: 874)] {
            let m = DeskMetrics.make(size: size)
            #expect(m.margin <= 6 && m.gap == 6 && m.tilePadding == 10)
            #expect(m.topBarHeight == 34 && m.footerHeight == 46)
            #expect(m.landscape == (size.width > size.height))
            // Top bar, grid and the always-present strip use every point: no band at top or bottom.
            let grid = m.gridHeight(screenHeight: size.height)
            #expect(2 * m.margin + m.topBarHeight + m.footerHeight + 2 * m.gap + grid == size.height)
            // The shift never pushes content past the margin.
            #expect(CGFloat(LayoutShift.reach) <= m.margin)
        }
    }

    @Test func theThreeStatesPickTheirTiles() {
        let idle = DeskState.make(laneCount: 0, attentionCount: 0)
        #expect(idle == .idle && idle.tiles == [.room, .weather])
        let lanes = DeskState.make(laneCount: 2, attentionCount: 0)
        #expect(lanes == .lanes && lanes.tiles == [.room, .lanes])      // Weather hidden
        let attention = DeskState.make(laneCount: 2, attentionCount: 1)
        #expect(attention == .attention && attention.tiles == [.room, .attention, .weather])
        #expect(attention.roomIsCompact && !idle.roomIsCompact && !lanes.roomIsCompact)
    }

    @Test func aProgressRowDecodesAndAnAreaOfOnlyProgressStillShows() throws {
        let json = #"{"attention": [{"id": "progress:indexer", "kind": "progress", "title": "文件索引", "done": 6400,"#
            + #" "total": 11268, "pct": 57, "eta": "04:10", "note": "images 2,100/5,632", "state": "running", "ts": "2026-10-28T12:00:00Z"}]}"#
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(json.utf8))
        let progress = try #require(p.attention.first?.progress)
        #expect(progress.summary == "6,400 / 11,268 · 预计 04:10" && progress.fraction == 0.57 && !progress.isFailed)
        #expect(!p.attention[0].isWarning)
        let state = DeskState.make(laneCount: 0, attentionCount: p.attention.count)
        #expect(state == .attention && state.tiles.contains(.attention))
    }

    @Test func progressAlongsideANormalItemKeepsBothAndAFailedOneIsAWarning() throws {
        let json = #"{"attention": [{"id": "e_1", "kind": "alert", "text": "Backup failed", "level": "warn", "ts": "x"},"#
            + #" {"id": "progress:drive", "kind": "progress", "title": "Drive", "done": 3, "state": "failed", "ts": "x"}]}"#
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(json.utf8))
        #expect(p.attention.map(\.id) == ["e_1", "progress:drive"] && p.attention[0].progress == nil)
        #expect(p.attention[1].isWarning && p.attention[1].progress?.summary == "3")
        let state = DeskState.make(laneCount: 2, attentionCount: p.attention.count)
        #expect(state.tiles == [.room, .attention, .weather])
    }

    @Test func readingsScaleWithTheTileAndTakeTheHeightTheSubLineLeaves() {
        let small = DeskMetrics.readingSize(tile: CGSize(width: 140, height: 140))
        let big = DeskMetrics.readingSize(tile: CGSize(width: 300, height: 300))
        #expect(big > small)
        #expect(DeskMetrics.readingSize(tile: .zero) >= 24)
        #expect(DeskMetrics.readingSize(tile: CGSize(width: 2000, height: 2000)) <= 240)
        // A wide, short tile (13 mini landscape): the height decides.
        let wide = CGSize(width: 380, height: 160)
        #expect(DeskMetrics.readingSize(tile: wide) == (160 - 48) / 1.05)
        #expect(DeskMetrics.readingSize(tile: wide, compact: true) < DeskMetrics.readingSize(tile: wide))
    }

    @Test func seatsReadAsOneLineWithTheHotOnesFlagged() {
        let seats = [DeskPayload.Seat(name: "Max", pct: 62), .init(name: "Team", pct: 97), .init(name: "Admin", pct: 18)]
        let line = SeatsLine.segments(seats)
        #expect(line.map(\.text) == ["Max 62%", "Team 97%", "Admin 18%"])
        #expect(line.map(\.red) == [false, true, false])
        #expect(SeatsLine.segments([.init(name: "X", pct: 90)])[0].red)
        #expect(SeatsLine.segments([]).isEmpty)
    }

    @Test func theNextEventIsTheEarliestTimedOneWithinADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events: [(title: String, start: Date, allDay: Bool)] = [
            ("Later", now.addingTimeInterval(3 * 3600), false),
            ("Holiday", now.addingTimeInterval(1800), true),
            ("Past", now.addingTimeInterval(-60), false),
            ("Far", now.addingTimeInterval(30 * 3600), false),
            ("Sooner", now.addingTimeInterval(1500), false),
        ]
        #expect(NextEvent.pick(events, now: now)?.title == "Sooner")
        #expect(NextEvent.pick(Array(events.prefix(1)) + [events[3]], now: now)?.title == "Later")
        #expect(NextEvent.pick([events[2], events[3], events[1]], now: now) == nil)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let next = NextEvent(title: "Exec call", start: Date(timeIntervalSince1970: 1_800_000_000 + 6 * 3600))
        #expect(next.when(now: now, calendar: utc) == "\(String(format: "%02d", utc.component(.hour, from: next.start))):\(String(format: "%02d", utc.component(.minute, from: next.start))) (6h)")
        #expect(NextEvent(title: "x", start: now.addingTimeInterval(25 * 60)).when(now: now, calendar: utc).hasSuffix("(25m)"))
    }

    @Test func theWorldClocksShowHoursAndMinutesInTheirOwnZones() {
        let t = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33:20 UTC
        #expect(DeskClocks.zones.map(\.label) == ["PHX", "KHI", "DEL"])
        #expect(DeskClocks.time(t, zone: "America/Phoenix") == "00:33")
        #expect(DeskClocks.time(t, zone: "Asia/Karachi") == "12:33")
        #expect(DeskClocks.time(t, zone: "Asia/Kolkata") == "13:03")
    }

    @Test func theDeskPayloadDecodesSeatsAndActivityAndToleratesTheirAbsence() throws {
        let json = #"{"attention": [], "seats": [{"name": "Max", "pct": 62, "bar": 0.62, "detail": "x"}],"#
            + #""activity": {"move_pct": null, "exercise_pct": null, "stand_pct": null, "steps": 6214}}"#
        let payload = try JSONDecoder().decode(DeskPayload.self, from: Data(json.utf8))
        #expect(payload.seats == [.init(name: "Max", pct: 62)])
        #expect(payload.activity?.steps == 6214 && payload.activity?.rings == nil)
        let rings = DeskPayload.Activity(movePct: 60, exercisePct: 150, standPct: 50, steps: 1)
        #expect(rings.rings?.exercise == 150)
        let bare = try JSONDecoder().decode(DeskPayload.self, from: Data(#"{"attention": []}"#.utf8))
        #expect(bare.seats.isEmpty && bare.activity == nil)
    }

    @Test func theLayoutShiftsEveryThreeMinutesWithinFourPoints() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LayoutShift.slot(at: t) == LayoutShift.slot(at: t.addingTimeInterval(1)))
        let next = LayoutShift.nextChange(after: t)
        #expect(next > t && next.timeIntervalSince(t) <= 180)
        #expect(LayoutShift.slot(at: next) == LayoutShift.slot(at: t) + 1)
        #expect(LayoutShift.slot(at: next.addingTimeInterval(-0.001)) == LayoutShift.slot(at: t))
        var seen = Set<[Int]>()
        for slot in 0..<500 {
            let o = LayoutShift.offset(slot: slot)
            #expect(abs(o.x) <= 4 && abs(o.y) <= 4)
            #expect(o == LayoutShift.offset(slot: slot))
            seen.insert([o.x, o.y])
        }
        #expect(seen.count > 50)
    }

    @Test func comfortFollowsTheAshraeZone() {
        #expect(ComfortPolicy.assess(tempC: 20, humidity: 30) == .comfortable)
        #expect(ComfortPolicy.assess(tempC: 26, humidity: 60) == .comfortable)
        #expect(ComfortPolicy.assess(tempC: 19.9, humidity: 45) == .chilly)
        #expect(ComfortPolicy.assess(tempC: 26.1, humidity: 45) == .warm)
        #expect(ComfortPolicy.assess(tempC: 22, humidity: 29) == .dry)
        #expect(ComfortPolicy.assess(tempC: 22, humidity: 61) == .humid)
        #expect(ComfortPolicy.assess(tempC: 18, humidity: 80) == .chilly)
        #expect(ComfortPolicy.assess(tempC: 30, humidity: 10) == .warm)
        #expect(ComfortPolicy.assess(tempC: nil, humidity: 40) == .unknown)
        #expect(ComfortPolicy.assess(tempC: 22, humidity: nil) == .unknown)
    }

    @Test func apparentTemperatureMatchesKnownValues() {
        #expect(abs(ComfortPolicy.apparentTemperature(tempC: 25, humidity: 50) - 26.2) < 0.1)
        #expect(abs(ComfortPolicy.apparentTemperature(tempC: 30, humidity: 70) - 35.8) < 0.1)
    }

    @Test func feelsLikeShowsOnlyWhenItDiffersByADegree() {
        #expect(ComfortPolicy.feelsLike(tempC: 22, humidity: 40) == nil)
        #expect(ComfortPolicy.feelsLike(tempC: 25, humidity: 50) == 26)
        #expect(ComfortPolicy.feelsLike(tempC: 30, humidity: 70) == 36)
        #expect(ComfortPolicy.feelsLike(tempC: nil, humidity: 70) == nil)
    }
}
