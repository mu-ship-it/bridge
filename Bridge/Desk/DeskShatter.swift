import SwiftUI
import UIKit

/// The hourly ceremony's picture: a snapshot of the old desk breaks into squares (the exit button's motif) that
/// fall away and show the fresh frame underneath. Pure timing here, so it is tested without a screen.
enum Shatter {
    static let tileSize: CGFloat = 34
    static let maxDelay: TimeInterval = 0.5
    static let fallDuration: TimeInterval = 0.7        // 0.5 s of delay + 0.7 s = the tiles are down at 1.2 s
    static let shakeAt: TimeInterval = 1.2
    static let shakeDuration: TimeInterval = 0.25
    static let shakeReach: CGFloat = 6
    static let shakeSwings = 3.0
    static let stragglerShare = 0.08
    static let stragglerFall: TimeInterval = 0.3
    static let stragglerAt: TimeInterval = shakeAt + shakeDuration
    static let total: TimeInterval = stragglerAt + stragglerFall + 0.05   // ≈ 1.8 s
    static let reduceDuration: TimeInterval = 0.4
    static let maxTilt = 12.0

    struct Tile: Equatable {
        let col: Int
        let row: Int
        let delay: TimeInterval
        let tilt: Double          // degrees at the end of the fall
        let straggler: Bool
    }

    /// 2:1 landscape ≈ 24 × 11, portrait 11 × 24.
    static func grid(for size: CGSize) -> (cols: Int, rows: Int) {
        (max(1, Int((size.width / tileSize).rounded())), max(1, Int((size.height / tileSize).rounded())))
    }

    static func tiles(cols: Int, rows: Int, using rng: inout some RandomNumberGenerator) -> [Tile] {
        var all: [Tile] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let straggler = Double.random(in: 0..<1, using: &rng) < stragglerShare
                all.append(Tile(col: col, row: row,
                                delay: straggler ? maxDelay : .random(in: 0...maxDelay, using: &rng),
                                tilt: .random(in: -maxTilt...maxTilt, using: &rng),
                                straggler: straggler))
            }
        }
        return all
    }

    /// 0 = still in place, 1 = gone. Stragglers hang until the shake has finished.
    static func fall(_ tile: Tile, at t: TimeInterval) -> Double {
        let start = tile.straggler ? stragglerAt : tile.delay
        let length = tile.straggler ? stragglerFall : fallDuration
        return min(1, max(0, (t - start) / length))
    }

    /// Gravity: ease-in, 1.5 screen heights; faded out over the last 30 % of the fall.
    static func offsetY(fall p: Double, height: CGFloat) -> CGFloat { CGFloat(p * p) * 1.5 * height }
    static func opacity(fall p: Double) -> Double { p < 0.7 ? 1 : max(0, 1 - (p - 0.7) / 0.3) }
}

/// One x-shake of the whole screen: ±6 pt, three swings, as `progress` runs 0 → 1.
struct ShakeEffect: GeometryEffect {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Shatter.shakeReach * CGFloat(sin(progress * Shatter.shakeSwings * 2 * .pi)), y: 0))
    }
}

/// Owns one shatter at a time. The step of the layout happens here, once per shatter, hidden by the snapshot.
@MainActor @Observable
final class ShatterDirector {
    struct Run {
        let image: UIImage
        let cols: Int
        let rows: Int
        let tiles: [Shatter.Tile]
        let start: Date
        let reduce: Bool
    }

    private(set) var run: Run?
    private(set) var shake = 0.0
    private var generation = 0

    /// Snapshot first, then `step` (the layout moves to its next offset with no animation), then the overlay.
    /// Mid-shatter the step still happens but the running overlay stays.
    func trigger(size: CGSize, reduce: Bool, snapshot: () -> UIImage?, step: () -> Void) {
        guard run == nil, let image = snapshot() else { step(); return }
        let grid = Shatter.grid(for: size)
        var rng = SystemRandomNumberGenerator()
        var plain = Transaction(animation: nil)
        plain.disablesAnimations = true
        withTransaction(plain) {
            step()
            run = Run(image: image, cols: grid.cols, rows: grid.rows,
                      tiles: reduce ? [] : Shatter.tiles(cols: grid.cols, rows: grid.rows, using: &rng),
                      start: Date(), reduce: reduce)
        }
        generation += 1
        let mine = generation
        Task { @MainActor in
            if !reduce {
                try? await Task.sleep(for: .seconds(Shatter.shakeAt))
                guard mine == generation else { return }
                withAnimation(.linear(duration: Shatter.shakeDuration)) { shake = 1 }
                try? await Task.sleep(for: .seconds(Shatter.total - Shatter.shakeAt))
            } else {
                try? await Task.sleep(for: .seconds(Shatter.reduceDuration + 0.05))
            }
            guard mine == generation else { return }
            withTransaction(plain) { shake = 0; run = nil }
        }
    }

    static func windowSnapshot() -> UIImage? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

/// The overlay: the snapshot as tiles, drawn in one Canvas. Never takes a touch.
struct ShatterOverlay: View {
    let run: ShatterDirector.Run

    var body: some View {
        Group {
            if run.reduce {
                CrossfadeSnapshot(image: run.image)
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(&context, size: size, t: timeline.date.timeIntervalSince(run.start))
                    }
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let image = context.resolve(Image(uiImage: run.image))
        let w = size.width / CGFloat(run.cols), h = size.height / CGFloat(run.rows)
        for tile in run.tiles {
            let p = Shatter.fall(tile, at: t)
            let opacity = Shatter.opacity(fall: p)
            if opacity <= 0 { continue }
            let rect = CGRect(x: CGFloat(tile.col) * w, y: CGFloat(tile.row) * h, width: w, height: h)
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: rect.midX, y: rect.midY + Shatter.offsetY(fall: p, height: size.height))
                layer.rotate(by: .degrees(tile.tilt * p))
                layer.translateBy(x: -rect.midX, y: -rect.midY)
                layer.clip(to: Path(rect))
                layer.draw(image, in: CGRect(origin: .zero, size: size))
            }
        }
    }
}

private struct CrossfadeSnapshot: View {
    let image: UIImage
    @State private var shown = true
    var body: some View {
        Image(uiImage: image).resizable().opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: Shatter.reduceDuration)) { shown = false } }
    }
}
