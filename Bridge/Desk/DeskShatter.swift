import SwiftUI
import UIKit

/// The quarter-hourly ceremony's picture: "frost, then falling leaves". A snapshot of the old desk is cut into
/// squares; frost spreads from one or two seeds (a tint fades in and a crack line grows round each square), then
/// the squares let go one by one and drift down like leaves. Pure timing here, so it is tested without a screen.
enum Shatter {
    static let tileSize: CGFloat = 24
    static let freezeSpan: TimeInterval = 1.6          // time for the frost to reach the farthest square
    static let freezeExponent = 0.85
    static let frostFade: TimeInterval = 0.22
    static let crackGrow: TimeInterval = 0.22
    static let hold: TimeInterval = 0.35
    static let holdJitter: TimeInterval = 0.72
    static let fallDuration: TimeInterval = 1.6
    static let shakeDuration: TimeInterval = 0.25
    static let shakeReach: CGFloat = 6
    static let shakeSwings = 3.0
    static let stragglerShare = 0.08
    static let stragglerFall: TimeInterval = 0.8
    static let reduceDuration: TimeInterval = 0.4
    static let secondSeedChance = 0.6
    static let frostColor = (r: 200.0 / 255, g: 230.0 / 255, b: 255.0 / 255, opacity: 0.06)

    struct Tile: Equatable {
        let col: Int
        let row: Int
        let freeze: TimeInterval   // when the frost reaches it
        let corner: Int            // 0 TL, 1 TR, 2 BR, 3 BL: the corner nearest its seed, where the crack starts
        var fallStart: TimeInterval
        let phase: Double          // ph
        let freq: Double           // fq
        let amp: Double            // pt
        let drift: Double          // pt
        let tilt: Double           // degrees
        let straggler: Bool
        var fallLength: TimeInterval { straggler ? Shatter.stragglerFall : Shatter.fallDuration }
    }

    /// 2:1 landscape ≈ 33 × 16, portrait 16 × 33.
    static func grid(for size: CGSize) -> (cols: Int, rows: Int) {
        (max(1, Int((size.width / tileSize).rounded())), max(1, Int((size.height / tileSize).rounded())))
    }

    private struct Raw { var col: Int; var row: Int; var d: Double; var corner: Int }

    static func tiles(cols: Int, rows: Int, size: CGSize, using rng: inout some RandomNumberGenerator) -> [Tile] {
        let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
        var seeds = [CGPoint(x: .random(in: 0...size.width, using: &rng), y: .random(in: 0...size.height, using: &rng))]
        if Double.random(in: 0..<1, using: &rng) < secondSeedChance {
            seeds.append(CGPoint(x: .random(in: 0...size.width, using: &rng), y: .random(in: 0...size.height, using: &rng)))
        }
        var raws: [Raw] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let cx = (CGFloat(col) + 0.5) * w, cy = (CGFloat(row) + 0.5) * h
                let seed = seeds.min { hypot($0.x - cx, $0.y - cy) < hypot($1.x - cx, $1.y - cy) }!
                let corner = (seed.x < cx ? 0 : 1) == 0 ? (seed.y < cy ? 0 : 3) : (seed.y < cy ? 1 : 2)
                raws.append(Raw(col: col, row: row, d: Double(hypot(seed.x - cx, seed.y - cy)), corner: corner))
            }
        }
        let dmax = max(raws.map(\.d).max() ?? 1, 1)
        var all: [Tile] = raws.map { r in
            let straggler = Double.random(in: 0..<1, using: &rng) < stragglerShare
            let ct = pow(r.d / dmax, freezeExponent) * freezeSpan * Double.random(in: 0.9...1.1, using: &rng)
            let sign = Bool.random(using: &rng) ? 8.0 : -8.0
            return Tile(col: r.col, row: r.row, freeze: ct, corner: r.corner,
                        fallStart: ct + hold + .random(in: 0...holdJitter, using: &rng),
                        phase: .random(in: 0..<(2 * .pi), using: &rng), freq: .random(in: 1...2.2, using: &rng),
                        amp: .random(in: 10...24, using: &rng), drift: .random(in: -20...20, using: &rng),
                        tilt: .random(in: -7...7, using: &rng) + sign, straggler: straggler)
        }
        // Stragglers hang until the shake has finished.
        let release = shakeAt(all) + shakeDuration
        for i in all.indices where all[i].straggler { all[i].fallStart = release }
        return all
    }

    /// When the last non-straggler square has finished its fall (= when the shake starts).
    static func shakeAt(_ tiles: [Tile]) -> TimeInterval {
        tiles.filter { !$0.straggler }.map { $0.fallStart + $0.fallLength }.max() ?? 0
    }
    static func stragglerAt(_ tiles: [Tile]) -> TimeInterval { shakeAt(tiles) + shakeDuration }
    static func total(_ tiles: [Tile]) -> TimeInterval { stragglerAt(tiles) + stragglerFall + 0.05 }

    /// 0 = still in place, 1 = gone.
    static func fall(_ tile: Tile, at t: TimeInterval) -> Double {
        min(1, max(0, (t - tile.fallStart) / tile.fallLength))
    }
    /// 0 → 1 over `frostFade` from the moment the square freezes (the crack grows over `crackGrow`, the same).
    static func frost(_ tile: Tile, at t: TimeInterval) -> Double {
        min(1, max(0, (t - tile.freeze) / frostFade))
    }

    /// Leaf: y = (0.35 f² + 0.65 f) × 1.1 screen heights.
    static func leafY(fall f: Double, height: CGFloat) -> CGFloat { CGFloat((0.35 * f * f + 0.65 * f) * 1.1) * height }
    private static func sway(_ tile: Tile, _ f: Double) -> Double {
        let sw = sin(tile.phase + f * tile.freq * 2 * .pi) - sin(tile.phase)
        return sw * min(1, 3 * f)
    }
    static func leafX(_ tile: Tile, fall f: Double) -> CGFloat { CGFloat(sway(tile, f) * tile.amp + tile.drift * f) }
    static func leafRotation(_ tile: Tile, fall f: Double) -> Double { sway(tile, f) * tile.tilt + tile.tilt * 0.3 * f }
    /// Opaque until the half-way point, then linear to nothing.
    static func opacity(fall p: Double) -> Double { p < 0.5 ? 1 : max(0, 1 - (p - 0.5) / 0.5) }

    /// Draw order: squares still in place first, then by fall progress, the furthest on top.
    static func drawOrder(_ tiles: [Tile], at t: TimeInterval) -> [Int] {
        tiles.indices.sorted { fall(tiles[$0], at: t) < fall(tiles[$1], at: t) }
    }
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
        let shakeAt: TimeInterval
        let total: TimeInterval
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
            let tiles = reduce ? [] : Shatter.tiles(cols: grid.cols, rows: grid.rows, size: size, using: &rng)
            run = Run(image: image, cols: grid.cols, rows: grid.rows, tiles: tiles, start: Date(), reduce: reduce,
                      shakeAt: Shatter.shakeAt(tiles), total: Shatter.total(tiles))
        }
        generation += 1
        let mine = generation
        let shakeAt = run?.shakeAt ?? 0, total = run?.total ?? 0
        Task { @MainActor in
            if !reduce {
                try? await Task.sleep(for: .seconds(shakeAt))
                guard mine == generation else { return }
                withAnimation(.linear(duration: Shatter.shakeDuration)) { shake = 1 }
                try? await Task.sleep(for: .seconds(total - shakeAt))
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
        let f = Shatter.frostColor
        let tint = Color(red: f.r, green: f.g, blue: f.b)
        for i in Shatter.drawOrder(run.tiles, at: t) {
            let tile = run.tiles[i]
            let p = Shatter.fall(tile, at: t)
            let opacity = Shatter.opacity(fall: p)
            if opacity <= 0 { continue }
            let frost = Shatter.frost(tile, at: t)
            let rect = CGRect(x: CGFloat(tile.col) * w, y: CGFloat(tile.row) * h, width: w, height: h)
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: rect.midX + Shatter.leafX(tile, fall: p),
                                  y: rect.midY + Shatter.leafY(fall: p, height: size.height))
                layer.rotate(by: .degrees(Shatter.leafRotation(tile, fall: p)))
                layer.translateBy(x: -rect.midX, y: -rect.midY)
                layer.drawLayer { piece in
                    piece.clip(to: Path(rect))
                    piece.draw(image, in: CGRect(origin: .zero, size: size))
                }
                if frost > 0 {
                    layer.fill(Path(rect), with: .color(tint.opacity(f.opacity * frost)))
                    layer.stroke(Self.perimeter(rect, from: tile.corner).trimmedPath(from: 0, to: frost),
                                 with: .color(.white.opacity(0.95)), lineWidth: 0.8)
                }
            }
        }
    }

    /// The square's outline, clockwise, starting at corner `c` (0 TL, 1 TR, 2 BR, 3 BL).
    private static func perimeter(_ r: CGRect, from c: Int) -> Path {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        var path = Path()
        path.move(to: pts[c])
        for k in 1...4 { path.addLine(to: pts[(c + k) % 4]) }
        return path
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
