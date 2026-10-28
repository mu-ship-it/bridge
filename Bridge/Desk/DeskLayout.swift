import Foundation
import CoreGraphics

/// How tall the Attention area is. Pure, so the policy is tested.
enum AttentionSizing {
    /// The most the area may take, of the screen's height.
    static let maxShare: CGFloat = 0.45
    /// Label row and padding, then one item row; what the sizing assumes a row costs.
    static let header: CGFloat = 48
    static let row: CGFloat = 88

    /// Zero items: nothing at all. Otherwise as tall as its items need, never above `maxShare`.
    static func height(items: Int, screen: CGFloat) -> CGFloat {
        guard items > 0 else { return 0 }
        let wanted = header + CGFloat(items) * row
        return min(wanted, screen * maxShare)
    }
}

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

/// Edge-to-edge desk layout: margins, gaps and padding per size class, plus the size of the big
/// readings. Pure, so a 13 mini and a 17 are tested the same way.
struct DeskMetrics: Equatable {
    var margin: CGFloat
    var gap: CGFloat
    var tilePadding: CGFloat
    /// Date, weather one-liner and exit button share this row.
    var topBarHeight: CGFloat
    var landscape: Bool

    /// `size` is the safe-area-inset screen: the notch and home indicator are already out of it.
    static func make(size: CGSize) -> DeskMetrics {
        DeskMetrics(margin: 6, gap: 6, tilePadding: 10,
                    topBarHeight: size.width > size.height ? 32 : 36,
                    landscape: size.width > size.height)
    }

    /// Height left for the tile grid: everything but the top bar, Attention and the gaps between.
    func gridHeight(screenHeight: CGFloat, attention: CGFloat) -> CGFloat {
        max(0, screenHeight - 2 * margin - topBarHeight - attention - (attention > 0 ? 2 : 1) * gap)
    }

    /// Point size of a big reading that must fit `tile` (its inner area), about five glyphs wide.
    /// `alone`: Room has the whole row, so the number may take about half its width and most of its height.
    static func readingSize(tile: CGSize, alone: Bool = false) -> CGFloat {
        if alone { return max(24, min(tile.width / 6.4, tile.height * 0.7, 240)) }
        return max(24, min(tile.width / 3.2, tile.height * 0.42, 160))
    }
}

/// Which tiles share the grid. Lanes only takes space when there are lanes.
enum DeskRow {
    static func showsLanes(laneCount: Int) -> Bool { laneCount > 0 }
}
