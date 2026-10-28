import Foundation
import CoreGraphics

/// OLED burn-in guard: the whole layout moves a few points every few minutes. Pure: the
/// offset is a function of the schedule slot, so the same slot always gives the same place.
enum LayoutShift {
    static let interval: TimeInterval = 180
    static let reach: Int = 4

    static func slot(at date: Date) -> Int { Int((date.timeIntervalSince1970 / interval).rounded(.down)) }

    /// When the slot after `date` begins.
    static func nextChange(after date: Date) -> Date {
        Date(timeIntervalSince1970: Double(slot(at: date) + 1) * interval)
    }

    /// Whole points in -reach...reach, hashed from the slot (SplitMix64), so no two runs of
    /// the schedule need to agree on a generator.
    static func offset(slot: Int) -> (x: Int, y: Int) {
        func mix(_ v: UInt64) -> UInt64 {
            var z = v &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let h = mix(UInt64(bitPattern: Int64(slot)))
        let span = UInt64(2 * reach + 1)
        return (Int(h % span) - reach, Int((h >> 32) % span) - reach)
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

    static func make(laneCount: Int, attentionCount: Int) -> DeskState {
        if attentionCount > 0 { return .attention }
        return laneCount > 0 ? .lanes : .idle
    }

    enum Tile: Equatable { case room, weather, lanes, attention }

    var tiles: [Tile] {
        switch self {
        case .idle: [.room, .weather]
        case .lanes: [.room, .lanes]
        case .attention: [.room, .attention, .weather]
        }
    }

    /// Room's number is smaller when it shares the row with three tiles.
    var roomIsCompact: Bool { self == .attention }
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
}
