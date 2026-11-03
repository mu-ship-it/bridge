import Foundation
import Testing
import UIKit
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
                  "stale_after_s": 90, "sources": [], "away_since": null, "away_s": null, "away_after_s": 600}}
    """

    @Test func decodesTheFullPayload() throws {
        let p = try JSONDecoder().decode(DeskPayload.self, from: Data(Self.full.utf8))
        #expect(p.time?.tz == "Asia/Shanghai" && p.time?.utcOffsetS == 28_800)
        #expect(p.weather?.tempC == 6.4 && p.weather?.code == 3 && p.weather?.place == "Shenyang")
        #expect(p.attention.map(\.id) == ["e_01", "b_muster_abc"])
        #expect(p.attention[0].speak && p.attention[0].isWarning && p.attention[0].title == nil)
        #expect(!p.attention[1].isWarning && p.attention[1].title == "Lanes · teal")
        #expect(p.presence?.present == true && p.presence?.ageS == 12 && p.presence?.staleAfterS == 90)
        #expect(p.presence?.awayS == nil && p.presence?.awayAfterS == 600)
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
        }
    }

    @Test func theThreeStatesPickTheirTiles() {
        let idle = DeskState.make(laneCount: 0, attentionCount: 0)
        #expect(idle == .idle && idle.tiles == [.room, .weather])
        let lanes = DeskState.make(laneCount: 2, attentionCount: 0)
        #expect(lanes == .lanes && lanes.tiles == [.room, .lanes])      // Weather hidden
        let attention = DeskState.make(laneCount: 0, attentionCount: 1)
        #expect(attention == .attention && attention.tiles == [.room, .attention, .weather] && !attention.weatherInTopRow)
        let both = DeskState.make(laneCount: 2, attentionCount: 1)       // lanes must not vanish behind Attention
        #expect(both == .attentionAndLanes && both.tiles == [.room, .attention, .lanes] && both.weatherInTopRow)
        #expect(attention.roomIsCompact && both.roomIsCompact && !idle.roomIsCompact && !lanes.roomIsCompact)
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
        #expect(state.tiles == [.room, .attention, .lanes])
        #expect(DeskState.make(laneCount: 0, attentionCount: p.attention.count).tiles == [.room, .attention, .weather])
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

    private func local(_ h: Int, _ m: Int, _ sec: Int = 0, day: Int = 28) -> (Date, Calendar) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Phoenix")!
        return (c.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: sec))!, c)
    }

    @MainActor @Test func aShatterStepsTheLayoutExactlyOnceAndTheOverlayIsGoneAfterSixSeconds() async throws {
        let director = ShatterDirector()
        let size = CGSize(width: 375, height: 812)
        var steps = 0
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        director.trigger(size: size, reduce: false, snapshot: { image }, step: { steps += 1 })
        #expect(steps == 1)
        #expect(director.run != nil)
        #expect(director.run?.tiles.count == 16 * 34)
        // A second trigger mid-shatter steps the layout but keeps the one overlay.
        director.trigger(size: size, reduce: false, snapshot: { image }, step: { steps += 1 })
        #expect(steps == 2 && director.run != nil)
        try await Task.sleep(for: .seconds(6))
        #expect(director.run == nil && director.shake == 0)
    }

    @Test func theShatterTimingFollowsTheSpec() {
        let land = CGSize(width: 812, height: 375)
        #expect(Shatter.grid(for: land) == (34, 16))
        #expect(Shatter.grid(for: CGSize(width: 375, height: 812)) == (16, 34))
        var rng = SystemRandomNumberGenerator()
        let tiles = Shatter.tiles(cols: 34, rows: 16, size: land, using: &rng)
        #expect(tiles.count == 34 * 16)
        // Freeze: within 1.6 s × 1.1, and the farthest squares freeze last; fall = freeze + 0.35 hold + ≤ 0.72.
        #expect(tiles.allSatisfy { $0.freeze >= 0 && $0.freeze <= 1.6 * 1.1 + 0.001 })
        let loose = tiles.filter { !$0.straggler }
        #expect(loose.allSatisfy { $0.fallStart >= $0.freeze + 0.35 && $0.fallStart <= $0.freeze + 0.35 + 0.72 + 0.001 })
        #expect(tiles.allSatisfy { $0.amp >= 10 && $0.amp <= 24 && $0.freq >= 1 && $0.freq <= 2.2 && abs($0.drift) <= 20 })
        #expect(tiles.allSatisfy { abs($0.tilt) >= 1 && abs($0.tilt) <= 15 })
        // Frost: nothing before freeze, full 0.22 s later; squares never move while freezing.
        let first = tiles[0]
        #expect(Shatter.frost(first, at: first.freeze - 0.01) == 0 && Shatter.frost(first, at: first.freeze + 0.23) == 1)
        #expect(Shatter.fall(first, at: first.freeze + 0.1) == 0)
        // The shake starts when the last loose square has landed; stragglers wait for it to finish, fall 0.8 s.
        let shakeAt = Shatter.shakeAt(tiles)
        #expect(loose.allSatisfy { Shatter.fall($0, at: shakeAt + 0.001) == 1 })
        let hung = tiles.filter(\.straggler)
        #expect(hung.allSatisfy { Shatter.fall($0, at: shakeAt + 0.2) == 0 && Shatter.fall($0, at: Shatter.stragglerAt(tiles) + 0.85) == 1 })
        #expect(Shatter.shakeDuration == 0.25 && Shatter.shakeReach == 6 && Shatter.shakeSwings == 3)
        #expect(Shatter.total(tiles) > shakeAt && Shatter.total(tiles) < 6)
        // Leaf: starts exactly in place, sways, drops 1.1 screen heights, fades from the half-way point.
        #expect(Shatter.leafY(fall: 0, height: 100) == 0 && Shatter.leafX(first, fall: 0) == 0 && Shatter.leafRotation(first, fall: 0) == 0)
        #expect(abs(Shatter.leafY(fall: 1, height: 100) - 110) < 0.001)
        #expect(Shatter.opacity(fall: 0.5) == 1 && Shatter.opacity(fall: 0.75) == 0.5 && Shatter.opacity(fall: 1) == 0)
        // Z-order: in place first, furthest-fallen last.
        let t = shakeAt * 0.6
        let order = Shatter.drawOrder(tiles, at: t).map { Shatter.fall(tiles[$0], at: t) }
        #expect(order == order.sorted())
    }

    @Test func glassFallsBackToFrostWithoutLiquidGlassAndFrostStaysFrost() {
        #expect(ShatterStyle.resolved(.glass, glassAvailable: true) == .glass)
        #expect(ShatterStyle.resolved(.glass, glassAvailable: false) == .frost)
        #expect(ShatterStyle.resolved(.frost, glassAvailable: true) == .frost)
        #expect(ShatterStyle.resolved(.frost, glassAvailable: false) == .frost)
        #expect(ShatterDemo.enabled(["DESK_SHATTER_DEMO": "1"]) && !ShatterDemo.enabled([:]) && !ShatterDemo.enabled(["DESK_SHATTER_DEMO": "0"]))
        #expect(ShatterDemo.sequence.map(\.style) == [.frost, .glass] && ShatterDemo.sequence.map(\.label) == ["霜", "玻璃"])
        #expect(ShatterDemo.launchDelay == 3 && ShatterDemo.pause == 4)
    }

    @MainActor @Test func frostHasNoCropsAndGlassCarriesOneCropPerSquare() {
        let size = CGSize(width: 375, height: 812)
        let image = UIGraphicsImageRenderer(size: size).image { $0.fill(CGRect(origin: .zero, size: size)) }
        let plain = ShatterDirector()
        plain.trigger(size: size, reduce: false, style: .frost, snapshot: { image }, step: {})
        #expect(plain.run?.style == .frost && plain.run?.crops.isEmpty == true)
        let glass = ShatterDirector()
        glass.trigger(size: size, reduce: false, style: .glass, glassAvailable: true, snapshot: { image }, step: {})
        #expect(glass.run?.style == .glass && glass.run?.crops.count == 16 * 34)
        #expect(glass.run?.crops.allSatisfy { $0 != nil } == true)
        let old = ShatterDirector()
        old.trigger(size: size, reduce: false, style: .glass, glassAvailable: false, snapshot: { image }, step: {})
        #expect(old.run?.style == .frost && old.run?.crops.isEmpty == true)
    }

    @Test func atMostOneHundredTwentyGlassPiecesOnlyInFlightOldestStartedFirst() {
        let land = CGSize(width: 812, height: 375)
        var rng = SystemRandomNumberGenerator()
        let tiles = Shatter.tiles(cols: 34, rows: 16, size: land, using: &rng)
        #expect(Shatter.glassCap == 120)
        let end = Shatter.total(tiles)
        var sawCap = false
        for t in stride(from: 0.0, through: end, by: 0.05) {
            let glass = Shatter.glassPieces(tiles, at: t)
            let flying = tiles.indices.filter { Shatter.fall(tiles[$0], at: t) > 0 && Shatter.fall(tiles[$0], at: t) < 1 }
            #expect(glass.count == min(120, flying.count))
            #expect(Set(glass).count == glass.count)
            // Only squares in flight; squares in place never become glass.
            #expect(glass.allSatisfy { let p = Shatter.fall(tiles[$0], at: t); return p > 0 && p < 1 })
            // Oldest-started first: every glass piece started no later than every flying square left in the Canvas.
            let rest = Set(flying).subtracting(glass)
            if let latest = glass.map({ tiles[$0].fallStart }).max(), let earliest = rest.map({ tiles[$0].fallStart }).min() {
                #expect(latest <= earliest)
                sawCap = true
            }
            // Returned in the same z-order as the Canvas (least fallen first).
            let falls = glass.map { Shatter.fall(tiles[$0], at: t) }
            #expect(falls == falls.sorted())
        }
        #expect(sawCap)   // 544 squares: the cap does bite mid-shatter
        #expect(Shatter.glassPieces(tiles, at: 0).isEmpty && Shatter.glassPieces(tiles, at: end).isEmpty)
        #expect(Shatter.glassPieces(tiles, at: end / 2, cap: 0).isEmpty && Shatter.glassPieces(tiles, at: end / 2, cap: 5).count <= 5)
        // Ties by fallStart go by index (the stragglers all let go together).
        let t = Shatter.stragglerAt(tiles) + 0.1
        let hung = Shatter.glassPieces(tiles, at: t, cap: 3)
        let firstHung = tiles.indices.filter { tiles[$0].straggler }.prefix(3)
        #expect(hung.count == min(3, firstHung.count) && Set(hung) == Set(firstHung))
    }

    @Test func theLayoutStepsExactlyOncePerQuarterHourAndNeverBetween() {
        // Across a whole day the offset is the same within a quarter hour and different at the next one.
        for h in 0..<24 {
            for q in 0..<4 {
                let (start, cal) = local(h, q * 15)
                let here = BurnIn.offset(at: start, calendar: cal)
                for m in [q * 15 + 1, q * 15 + 7, q * 15 + 14] {
                    #expect(BurnIn.offset(at: local(h, m, 59).0, calendar: cal) == here)
                    #expect(BurnIn.slot(at: local(h, m).0, calendar: cal) == h * 4 + q)
                }
                let nextMinute = (q + 1) * 15
                let (next, _) = nextMinute == 60
                    ? local((h + 1) % 24, 0, 0, day: h == 23 ? 29 : 28)
                    : local(h, nextMinute)
                #expect(BurnIn.offset(at: next, calendar: cal) != here, "slot \(h):\(q * 15)")
                #expect(BurnIn.slot(at: next, calendar: cal) != h * 4 + q)
            }
        }
        // Eight distinct points, all on the ±4 grid, never the centre, and the walk repeats every eight slots.
        let (_, cal) = local(0, 0)
        let walk = (0..<8).map { BurnIn.offset(at: local($0 / 4, ($0 % 4) * 15).0, calendar: cal) }
        #expect(Set(walk.map { "\($0.x),\($0.y)" }).count == 8)
        #expect(walk.allSatisfy { abs($0.x) <= BurnIn.reach && abs($0.y) <= BurnIn.reach && ($0.x, $0.y) != (0, 0) })
        #expect(BurnIn.offset(at: local(2, 15).0, calendar: cal) == walk[1])
        #expect(BurnIn.slot(at: local(23, 45).0, calendar: cal) == 95)
        #expect(CGFloat(BurnIn.reach) <= DeskMetrics.make(size: CGSize(width: 375, height: 812)).margin)
    }

    @Test func lightsOutIsThreeToThreeOhOneOrSixtySecondsFromATap() {
        let (_, cal) = local(0, 0)
        func off(_ h: Int, _ m: Int, _ s: Int = 0, manual: Date? = nil) -> Bool {
            BurnIn.lightsOut(at: local(h, m, s).0, manualSince: manual, calendar: cal)
        }
        #expect(!off(2, 59, 59) && off(3, 0) && off(3, 0, 59) && !off(3, 1))
        let (t, _) = local(14, 0)
        #expect(BurnIn.lightsOut(at: t.addingTimeInterval(59), manualSince: t, calendar: cal))
        #expect(!BurnIn.lightsOut(at: t.addingTimeInterval(60), manualSince: t, calendar: cal))
        #expect(!BurnIn.lightsOut(at: t.addingTimeInterval(-1), manualSince: t, calendar: cal))
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
