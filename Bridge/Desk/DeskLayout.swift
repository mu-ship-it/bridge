import Foundation
import CoreGraphics
import SwiftUI

/// OLED burn-in protection, all of it visible and none of it random:
///  - Hourly sweep: at every :00 a thin light line crosses the screen in 1 s, and as it passes the whole layout
///    steps to its next offset (one step per hour round the 8 points of a ±4 pt grid) in a 0.3 s ease. The layout
///    never moves at any other time, and content never changes place.
///  - Dim when away (BrightnessPolicy) and a nightly lights-out: 03:00–03:01 (or 60 s from a two-finger tap)
///    the screen is black but for the sleeping face.
enum BurnIn {
    static let lightsOutHour = 3
    static let lightsOutLength: TimeInterval = 60
    static let sweepDuration: TimeInterval = 1
    static let stepDuration: TimeInterval = 0.3
    /// When in the sweep the layout steps: so the 0.3 s move ends with the line leaving the screen.
    static let stepAt: TimeInterval = sweepDuration - stepDuration
    static let reach = 4
    static var stepAnimation: Animation { .easeInOut(duration: stepDuration) }

    /// The eight non-centre points of the ±4 grid, in the order the hours walk them.
    static let ring: [(x: Int, y: Int)] = [(4, 0), (4, 4), (0, 4), (-4, 4), (-4, 0), (-4, -4), (0, -4), (4, -4)]

    /// Constant within an hour (24 is a multiple of 8, so the walk also continues across midnight). The view
    /// adopts a new value only when a sweep passes.
    static func offset(at date: Date, calendar: Calendar = .current) -> (x: Int, y: Int) {
        ring[calendar.component(.hour, from: date) % ring.count]
    }

    /// The hour the sweep belongs to: it changes at :00 and nowhere else.
    static func sweepHour(at date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date)
    }

    /// `manualSince`: when a two-finger tap started it by hand.
    static func lightsOut(at date: Date, manualSince: Date? = nil, calendar: Calendar = .current) -> Bool {
        if let manualSince, date >= manualSince, date.timeIntervalSince(manualSince) < lightsOutLength { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return c.hour == lightsOutHour && c.minute == 0
    }
}

/// What the main area shows, beside Room. Pure, so the three states are tested.
enum DeskState: Equatable {
    /// Nothing to report: Room | Weather.
    case idle
    /// Lanes are running: Room | Lanes (Weather hidden).
    case lanes
    /// Something wants Mu: Room | Attention | Weather.
    case attention
    /// Both: Room | Attention | Lanes. Weather yields its place to the top row.
    case attentionAndLanes

    static func make(laneCount: Int, attentionCount: Int) -> DeskState {
        if attentionCount > 0 { return laneCount > 0 ? .attentionAndLanes : .attention }
        return laneCount > 0 ? .lanes : .idle
    }

    enum Tile: Equatable { case room, weather, lanes, attention }

    var tiles: [Tile] {
        switch self {
        case .idle: [.room, .weather]
        case .lanes: [.room, .lanes]
        case .attention: [.room, .attention, .weather]
        case .attentionAndLanes: [.room, .attention, .lanes]
        }
    }

    /// Room's number is smaller when it shares the row with three tiles.
    var roomIsCompact: Bool { self == .attention || self == .attentionAndLanes }

    /// With Weather out of the grid, its one-liner sits in the top row, left of the seats.
    var weatherInTopRow: Bool { self == .attentionAndLanes }
}

/// Edge-to-edge desk layout: margins, gaps and padding, plus the size of the big readings.
/// Pure, so a 13 mini and a 17 are tested the same way.
struct DeskMetrics: Equatable {
    var margin: CGFloat
    var gap: CGFloat
    var tilePadding: CGFloat
    /// Date, seats line and exit button share this row.
    var topBarHeight: CGFloat
    /// Clocks, next event and rings: always present.
    var footerHeight: CGFloat
    var landscape: Bool

    /// `size` is the safe-area-inset screen: the notch and home indicator are already out of it.
    static func make(size: CGSize) -> DeskMetrics {
        DeskMetrics(margin: 6, gap: 6, tilePadding: 10, topBarHeight: 34, footerHeight: 46,
                    landscape: size.width > size.height)
    }

    /// Height left for the tile grid: everything but the two bars and the gaps between.
    func gridHeight(screenHeight: CGFloat) -> CGFloat {
        max(0, screenHeight - 2 * margin - topBarHeight - footerHeight - 2 * gap)
    }

    /// Point size of a big reading that must fit `tile` (its inner area): about five glyphs wide ("23.6°" is
    /// 2.4 em), and as tall as the header and the one sub line leave. `compact` for Room beside two other tiles.
    static func readingSize(tile: CGSize, compact: Bool = false) -> CGFloat {
        let size = max(24, min(tile.width / 2.6, (tile.height - 48) / 1.05, 240))
        return compact ? max(24, size * 0.72) : size
    }

    /// The face is mono 26 pt; a mono glyph is about 0.6 em wide. The widest face is `(⌐■_■)` or `(-_-) zZ`.
    static let faceSize: CGFloat = 26
    static let faceGlyphs = 8

    var faceWidth: CGFloat { CGFloat(Self.faceGlyphs) * Self.faceSize * 0.6 }

    /// Mono size of the world-clock digits: smaller in portrait, where the strip also holds the face.
    var clockSize: CGFloat { landscape ? 20 : 12 }
    var clockGap: CGFloat { landscape ? 16 : 6 }

    /// What the three clocks (label ~24 pt, 5 mono digits at 0.6 em, 4 pt between) need.
    var clocksWidth: CGFloat { 3 * (24 + 4 + 5 * 0.6 * clockSize) + 2 * clockGap }

    /// Width left for the clocks once the face has its own.
    func clocksRoom(screenWidth: CGFloat) -> CGFloat {
        screenWidth - 2 * margin - 2 * 12 - faceWidth - clockGap
    }
}
