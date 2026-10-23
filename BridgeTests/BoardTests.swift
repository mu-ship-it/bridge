import Foundation
import Testing
@testable import Bridge

@Suite struct BoardTests {
    static let json = """
    {"board": {"title": "Lanes board", "updated_at": "2026-10-23T02:40:00Z", "sections": [
      {"title": "Lanes", "rows": [
        {"label": "cyan", "detail": "Mini", "color": "#00d7ff", "bar": 0.25, "bar_faded": null,
         "value": "24m / 98m", "state": "ok", "url": "claude://claude.ai/chat/abc"},
        {"label": "red", "detail": null, "color": null, "bar": 1.4, "bar_faded": null, "value": null,
         "state": "over", "url": null},
        {"label": "new", "state": "exploded"}]},
      {"title": "Usage", "rows": [{"label": "MAX", "color": "#888", "bar": 0.31, "bar_faded": 0.12, "value": "31%"}]}
    ]}, "age_s": 42}
    """

    private func response() throws -> BoardResponse {
        try JSONDecoder().decode(BoardResponse.self, from: Data(Self.json.utf8))
    }

    private func snapshot(_ board: Board, received: TimeInterval, now: Date) -> BoardSnapshot {
        BoardSnapshot(name: "muster", board: board, receivedAt: now.addingTimeInterval(-received), fetchedAt: now)
    }

    @Test func decodesTheContract() throws {
        let decoded = try response()
        #expect(decoded.ageSeconds == 42)
        let rows = decoded.board.sections[0].rows
        #expect(rows[0].label == "cyan" && rows[0].bar == 0.25 && rows[0].barFaded == nil && rows[0].state == .ok)
        #expect(rows[0].url == "claude://claude.ai/chat/abc")
        #expect(rows[2].state == nil)                               // unknown state is not a decode failure
        #expect(decoded.board.sections[1].rows[0].barFaded == 0.12)
    }

    @Test func receivedAtIsFetchTimeMinusAge() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snap = BoardSnapshot(name: "muster", response: try response(), now: now)
        #expect(snap.receivedAt == now.addingTimeInterval(-42))
        #expect(!snap.isStale(at: now))
        #expect(snap.isStale(at: now.addingTimeInterval(140)))      // 182 s old
        #expect(snap.staleAt == now.addingTimeInterval(138))
    }

    @Test func barsClampAndOverIsFull() {
        #expect(Board.Row(label: "a", bar: 1.4).fill == 1)
        #expect(Board.Row(label: "a", bar: -1).fill == 0)
        #expect(Board.Row(label: "a").fill == 0)
        #expect(Board.Row(label: "a", bar: 0.2, state: .over).fill == 1)
        #expect(Board.Row(label: "a", barFaded: 0.5).fadedFill == 0.5)
        #expect(Board.Row(label: "a", state: .stalled).isMuted && Board.Row(label: "a", state: .idle).isMuted)
        #expect(!Board.Row(label: "a", state: .over).isMuted)
    }

    @Test func hexColours() {
        #expect(Board.Row.rgb("#00d7ff") == 0x00d7ff)
        #expect(Board.Row.rgb("#888") == 0x888888)
        #expect(Board.Row.rgb("00d7ff") == nil && Board.Row.rgb("#12345") == nil && Board.Row.rgb(nil) == nil)
    }

    @Test func linesFitTheLimitWithHeadings() throws {
        let board = try response().board                          // 3 lanes + 1 usage
        let (all, none) = board.lines(limit: 20)
        #expect(all.count == 6 && none == 0)
        #expect(all[0] == .heading("Lanes") && all[4] == .heading("Usage"))

        let (three, hidden) = board.lines(limit: 3, headings: false)
        #expect(three.count == 3 && hidden == 1)
        #expect(!three.contains { if case .heading = $0 { true } else { false } })

        // A heading never ends a column without one of its rows.
        let (four, rest) = board.lines(limit: 5)
        #expect(four.count == 4 && rest == 1)
    }

    @Test func oneSectionHasNoHeading() {
        let board = Board(title: nil, sections: [.init(title: "Only", rows: [.init(label: "a")])])
        #expect(board.lines(limit: 5).lines == [.row(.init(label: "a"))])
    }

    @Test func columnsSplitSections() {
        let rows = (0..<4).map { Board.Row(label: "\($0)") }
        let board = Board(title: "t", sections: [.init(title: "A", rows: rows), .init(title: "B", rows: rows),
                                                  .init(title: "C", rows: [rows[0]])])
        let columns = board.columns(2)
        #expect(columns.count == 2)
        #expect(columns.flatMap(\.sections).map(\.title) == ["A", "B", "C"])
        #expect(columns[0].sections.map(\.title) == ["A"])
        #expect(Board.sample.columns(1).count == 1)
    }

    @Test func reloadOnlyWhenTheWidgetWouldChange() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let board = try response().board
        var other = board
        other.sections[0].rows[0].value = "25m / 98m"
        var restamped = board
        restamped.updatedAt = "2026-10-23T02:41:00Z"

        #expect(BoardSnapshot.needsReload(shown: nil, fresh: snapshot(board, received: 5, now: now), now: now))
        #expect(BoardSnapshot.needsReload(shown: snapshot(board, received: 30, now: now),
                                          fresh: snapshot(other, received: 5, now: now), now: now))
        // Same content, only updated_at moved, widget copy young: no reload.
        #expect(!BoardSnapshot.needsReload(shown: snapshot(board, received: 30, now: now),
                                           fresh: snapshot(restamped, received: 5, now: now), now: now))
        // Same content but the widget's copy is about to go stale while the box's is fresh: reload.
        #expect(BoardSnapshot.needsReload(shown: snapshot(board, received: 160, now: now),
                                          fresh: snapshot(board, received: 5, now: now), now: now))
        // Same content, box has nothing newer either: no reload (stale is the truth).
        #expect(!BoardSnapshot.needsReload(shown: snapshot(board, received: 400, now: now),
                                           fresh: snapshot(board, received: 400, now: now), now: now))
    }

    @Test func boardNames() {
        #expect(BoardName.normalized(nil) == "muster")
        #expect(BoardName.normalized(" Lanes ") == "lanes")
        #expect(BoardName.normalized("a/b") == "muster")
        #expect(BoardName.isValid("my_board-2") && !BoardName.isValid("-x") && !BoardName.isValid(String(repeating: "a", count: 33)))
    }

    @Test func rowTapRoundTripsTheURL() throws {
        for raw in ["claude://claude.ai/chat/0b6f-uuid", "https://example.com/a?b=c&d=e#f"] {
            let url = try #require(BoardRoute.url(for: raw))
            #expect(url.scheme == "bridge" && url.host() == "board")
            #expect(BoardRoute.target(from: url)?.absoluteString == raw)
        }
        #expect(BoardRoute.url(for: nil) == nil)
        #expect(BoardRoute.url(for: "bridge://board/open?u=x") == nil)          // no loops
        #expect(BoardRoute.url(for: "no scheme") == nil)
        #expect(BoardRoute.target(from: URL(string: "bridge://board/open?u=bridge-widget://status")!) == nil)
        #expect(BoardRoute.target(from: URL(string: "bridge://suggest/app.x")!) == nil)
    }

    @Test func watcherReloadsOnceOnlyOnChange() async throws {
        let board = try response().board
        let now = Date()
        let reloads = Counter()
        let shown = snapshot(board, received: 30, now: now)
        var edited = board
        edited.title = "new"
        let changed = edited
        let same = BoardWatcher(names: { ["muster", "other"] }, fetch: { _ in self.snapshot(board, received: 5, now: now) },
                                shown: { _ in shown }, reload: { reloads.add() })
        #expect(await same.check(now: now) == false)
        let different = BoardWatcher(names: { ["muster", "other"] },
                                     fetch: { _ in self.snapshot(changed, received: 5, now: now) },
                                     shown: { _ in shown }, reload: { reloads.add() })
        #expect(await different.check(now: now) == true)
        let failing = BoardWatcher(names: { ["muster"] }, fetch: { _ in nil }, shown: { _ in nil }, reload: { reloads.add() })
        #expect(await failing.check(now: now) == false)
        let none = BoardWatcher(names: { [] }, fetch: { _ in nil }, shown: { _ in nil }, reload: { reloads.add() })
        #expect(await none.check(now: now) == false)
        #expect(reloads.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
