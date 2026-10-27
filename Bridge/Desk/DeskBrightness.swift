import SwiftUI
import UIKit

/// How bright the desk display should be. Pure, so the rules are pinned by tests:
/// Mu at the desk → 0.85 (0.5 between 23:00 and 07:00), away → 0.10, never 0. A new attention
/// item lights the screen for 30 s even when he is away. Presence comes from the box's desk
/// payload; a report older than 90 s (its age at fetch plus the time since) counts as away.
enum BrightnessPolicy {
    static let present: CGFloat = 0.85
    static let presentAtNight: CGFloat = 0.5
    static let away: CGFloat = 0.10
    static let arrivalHold: TimeInterval = 30
    static let presenceStale: TimeInterval = 90
    /// Night is [nightStarts, nightEnds) in local hours, across midnight.
    static let nightStarts = 23
    static let nightEnds = 7

    static func isPresent(_ presence: DeskPayload.Presence?, fetchedAt: Date?, now: Date) -> Bool {
        guard let presence, presence.present, let ageS = presence.ageS, let fetchedAt else { return false }
        let stale = TimeInterval(presence.staleAfterS ?? Int(presenceStale))
        return TimeInterval(ageS) + now.timeIntervalSince(fetchedAt) <= stale
    }

    static func isNight(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= nightStarts || hour < nightEnds
    }

    static func level(present: Bool, lastArrival: Date?, now: Date, calendar: Calendar = .current) -> CGFloat {
        let lit: Bool = if let lastArrival { now >= lastArrival && now.timeIntervalSince(lastArrival) < arrivalHold } else { false }
        guard present || lit else { return away }
        return isNight(now, calendar: calendar) ? presentAtNight : Self.present
    }
}

/// Drives the screen's brightness while the desk shows: remembers Mu's own level, fades to the
/// policy's level over a second whenever it changes, and puts his level back on the way out.
@MainActor
final class DeskBrightness {
    static let fade: Duration = .seconds(1)
    private static let steps = 20

    private var saved: CGFloat?
    private var active = false
    private var target: CGFloat?
    private var fading: Task<Void, Never>?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    /// Start (or resume after the background): remember the current level once.
    func begin() {
        if saved == nil { saved = screen?.brightness }
        target = nil
        active = true
    }

    func apply(_ level: CGFloat) {
        guard active, level != target, let screen else { return }
        target = level
        fading?.cancel()
        let from = screen.brightness
        fading = Task { @MainActor in
            for step in 1...Self.steps {
                try? await Task.sleep(for: Self.fade / Self.steps)
                if Task.isCancelled { return }
                screen.brightness = from + (level - from) * CGFloat(step) / CGFloat(Self.steps)
            }
        }
    }

    /// Leaving the desk, or the app leaving the screen: Mu's own level back.
    func end() {
        active = false
        fading?.cancel()
        fading = nil
        target = nil
        if let saved, let screen { screen.brightness = saved }
        saved = nil
    }
}
