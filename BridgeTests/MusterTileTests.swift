import Foundation
import Testing
@testable import Bridge

@Suite struct MusterTileTests {
    typealias Row = Board.Row

    static let board = Board(title: "Muster", updatedAt: nil, sections: [
        Board.Section(title: "Usage", rows: [Row(label: "MAX", color: "#888", bar: 0.31, value: "31%", state: .ok)]),
        Board.Section(title: "Lanes", rows: [
            Row(label: "cyan", detail: "Mini · Building widgets", color: "#00d7ff", bar: 0.25, value: "24m / 98m", state: .ok),
            Row(label: "amber", detail: "Box · Migrating the DB", color: "#ffb000", bar: 1.2, value: "130m / 90m", state: .over),
            Row(label: "lime", detail: "Waiting on review", color: "#7cff4f", bar: 0.6, value: "", state: .stalled),
        ]),
    ])

    @Test func lanesComeFromTheLanesSection() {
        let tile = MusterTile(Self.board)
        #expect(tile.lanes.map(\.name) == ["cyan", "amber", "lime"])
        #expect(tile.hidden == 0 && !tile.isEmpty)
    }

    @Test func eachLaneCarriesColourHostStateAndClock() {
        let (cyan, amber, lime) = { let l = MusterTile(Self.board).lanes; return (l[0], l[1], l[2]) }()
        #expect(cyan.rgb == 0x00d7ff && cyan.host == "Mini" && cyan.state == "ok" && cyan.clock == "24m / 98m" && !cyan.isOver)
        #expect(amber.rgb == 0xffb000 && amber.host == "Box" && amber.state == "over" && amber.isOver)
        // Over draws a full bar whatever `bar` says (the widget's own rule).
        #expect(amber.row.fill == 1 && cyan.row.fill == 0.25)
        // No " · " → no host; an empty value → no clock.
        #expect(lime.host == nil && lime.clock == nil && lime.state == "stalled")
    }

    @Test func withoutALanesSectionTheFirstSectionIsUsed() {
        let board = Board(title: nil, updatedAt: nil, sections: [Board.Section(title: "Today", rows: [Row(label: "a")])])
        let tile = MusterTile(board)
        #expect(tile.lanes.map(\.name) == ["a"] && tile.lanes[0].state == nil && tile.lanes[0].rgb == nil)
    }

    @Test func noBoardOrNoRowsIsEmpty() {
        #expect(MusterTile(nil).isEmpty)
        #expect(MusterTile(Board(title: nil, updatedAt: nil, sections: [])).isEmpty)
        #expect(MusterTile(Board(title: nil, updatedAt: nil, sections: [Board.Section(title: "Lanes", rows: [])])).isEmpty)
    }

    @Test func moreLanesThanFitAreCounted() {
        let rows = (1...6).map { Row(label: "l\($0)") }
        let tile = MusterTile(Board(title: nil, updatedAt: nil, sections: [Board.Section(title: "lanes", rows: rows)]))
        #expect(tile.lanes.count == MusterTile.shown && tile.hidden == 2)
    }

    @Test func hostIsTheDetailsFirstPart() {
        #expect(MusterTile.host(of: "Mini · a · b") == "Mini")
        #expect(MusterTile.host(of: "Box") == nil)
        #expect(MusterTile.host(of: nil) == nil)
        #expect(MusterTile.host(of: " · x") == nil)
    }

    @Test func theTileReadsTheBoardWidgetsDefaultBoard() {
        #expect(MusterTile.boardName == "muster")
    }
}
