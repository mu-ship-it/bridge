import Foundation

/// How tall the Attention area is. Pure, so the policy is tested.
enum AttentionSizing {
    /// One line: the "nothing needs you" strip.
    static let strip: CGFloat = 48
    /// The most the area may take, of the screen's height.
    static let maxShare: CGFloat = 0.45
    /// Label row and padding, then one item row; what the sizing assumes a row costs.
    static let header: CGFloat = 48
    static let row: CGFloat = 88

    /// Zero items: the strip. Otherwise as tall as its items need, never above `maxShare`.
    static func height(items: Int, screen: CGFloat) -> CGFloat {
        guard items > 0 else { return strip }
        let wanted = header + CGFloat(items) * row
        return max(strip, min(wanted, screen * maxShare))
    }
}

/// OLED burn-in guard: the whole layout moves a few points every few minutes. Pure: the
/// offset is a function of the schedule slot, so the same slot always gives the same place.
enum LayoutShift {
    static let interval: TimeInterval = 180
    static let reach: Int = 6

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
