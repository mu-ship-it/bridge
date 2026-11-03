import SwiftUI
import UIKit

/// The quarter-hourly ceremony's picture: "frost, then falling leaves". A snapshot of the old desk is cut into
/// squares; frost spreads from one or two seeds (a tint fades in and a crack line grows round each square), then
/// the squares let go one by one and drift down like leaves. Pure timing here, so it is tested without a screen.
///
/// Two looks on the same timeline (ShatterStyle): `.frost` (the approved one, used by the quarter-hourly step) and
/// `.glass`, where the freeze grows a glass rim instead of the crack and the squares in flight are real Liquid Glass.
enum ShatterStyle: Equatable, Sendable {
    case frost, glass

    /// Liquid Glass needs iOS 26; below that `.glass` plays as `.frost`.
    static func resolved(_ requested: ShatterStyle, glassAvailable: Bool) -> ShatterStyle {
        requested == .glass && glassAvailable ? .glass : .frost
    }
    static var glassAvailable: Bool {
        if #available(iOS 26, *) { return true } else { return false }
    }
}

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
    /// GlassBench on the 13 mini: one GlassEffectContainer holds 60 fps to ~230 moving squares; 120 leaves headroom.
    static let glassCap = 120
    static let glassCornerRadius: CGFloat = 3

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

    /// `.glass`: which squares are real glass right now. Only squares in flight (0 < fall < 1), at most `cap`,
    /// the oldest-started first (ties by index); the rest stay in the Canvas. Returned in draw order.
    static func glassPieces(_ tiles: [Tile], at t: TimeInterval, cap: Int = glassCap) -> [Int] {
        guard cap > 0 else { return [] }
        let flying = tiles.indices.filter { let p = fall(tiles[$0], at: t); return p > 0 && p < 1 }
        let chosen = flying.sorted { (tiles[$0].fallStart, $0) < (tiles[$1].fallStart, $1) }.prefix(cap)
        return chosen.sorted { (fall(tiles[$0], at: t), $0) < (fall(tiles[$1], at: t), $1) }
    }
}

/// The demo (launch with DESK_SHATTER_DEMO=1, or a three-finger tap): frost once, a pause, glass once.
enum ShatterDemo {
    static let launchDelay: TimeInterval = 3
    static let pause: TimeInterval = 4
    static let sequence: [(style: ShatterStyle, label: String)] = [(.frost, "霜"), (.glass, "玻璃")]
    static func enabled(_ environment: [String: String]) -> Bool { environment["DESK_SHATTER_DEMO"] == "1" }
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
        var style: ShatterStyle = .frost
        /// `.glass`: each square's own crop of the snapshot (nil where the crop failed), the content of its glass piece.
        var crops: [UIImage?] = []
    }

    private(set) var run: Run?
    private(set) var shake = 0.0
    /// The demo's corner label ("霜" / "玻璃") while its shatter plays.
    private(set) var demoLabel: String?
    private(set) var demoRunning = false
    private var generation = 0

    /// Snapshot first, then `step` (the layout moves to its next offset with no animation), then the overlay.
    /// Mid-shatter the step still happens but the running overlay stays. `.glass` plays as `.frost` below iOS 26.
    func trigger(size: CGSize, reduce: Bool, style: ShatterStyle = .frost,
                 glassAvailable: Bool = ShatterStyle.glassAvailable,
                 snapshot: () -> UIImage?, step: () -> Void) {
        guard run == nil, let image = snapshot() else { step(); return }
        let style = ShatterStyle.resolved(style, glassAvailable: glassAvailable)
        let grid = Shatter.grid(for: size)
        var rng = SystemRandomNumberGenerator()
        var plain = Transaction(animation: nil)
        plain.disablesAnimations = true
        withTransaction(plain) {
            step()
            let tiles = reduce ? [] : Shatter.tiles(cols: grid.cols, rows: grid.rows, size: size, using: &rng)
            run = Run(image: image, cols: grid.cols, rows: grid.rows, tiles: tiles, start: Date(), reduce: reduce,
                      shakeAt: Shatter.shakeAt(tiles), total: Shatter.total(tiles), style: style,
                      crops: style == .glass ? Self.crops(image, tiles: tiles, cols: grid.cols, rows: grid.rows, size: size) : [])
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

    /// Frost once, `ShatterDemo.pause`, glass once, each with its corner label; then back to normal.
    /// A second call while the demo runs does nothing.
    func demo(size: @escaping () -> CGSize, reduce: Bool, glassAvailable: Bool = ShatterStyle.glassAvailable,
              snapshot: @escaping () -> UIImage?, step: @escaping () -> Void) async {
        guard !demoRunning else { return }
        demoRunning = true
        defer { demoRunning = false; demoLabel = nil }
        for (k, item) in ShatterDemo.sequence.enumerated() {
            if k > 0 { try? await Task.sleep(for: .seconds(ShatterDemo.pause)) }
            while run != nil { try? await Task.sleep(for: .milliseconds(100)) }   // a scheduled one is playing
            trigger(size: size(), reduce: reduce, style: item.style, glassAvailable: glassAvailable,
                    snapshot: snapshot, step: step)
            guard run != nil else { continue }
            demoLabel = item.label
            while run != nil { try? await Task.sleep(for: .milliseconds(100)) }
            demoLabel = nil
        }
    }

    /// The square at (col, row) cut from the snapshot, in the snapshot's own pixels.
    static func crops(_ image: UIImage, tiles: [Shatter.Tile], cols: Int, rows: Int, size: CGSize) -> [UIImage?] {
        guard let cg = image.cgImage, size.width > 0, size.height > 0 else { return tiles.map { _ in nil } }
        let sx = CGFloat(cg.width) / size.width, sy = CGFloat(cg.height) / size.height
        let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
        return tiles.map { tile in
            let r = CGRect(x: CGFloat(tile.col) * w * sx, y: CGFloat(tile.row) * h * sy, width: w * sx, height: h * sy).integral
            return cg.cropping(to: r).map { UIImage(cgImage: $0, scale: image.scale, orientation: .up) }
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

/// The overlay: the snapshot as tiles, drawn in one Canvas; with `.glass`, the squares in flight (up to the cap)
/// are real Liquid Glass pieces above it, all in one GlassEffectContainer. Never takes a touch.
struct ShatterOverlay: View {
    let run: ShatterDirector.Run

    var body: some View {
        Group {
            if run.reduce {
                CrossfadeSnapshot(image: run.image)
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSince(run.start)
                    let glass = run.style == .glass && !run.crops.isEmpty ? Shatter.glassPieces(run.tiles, at: t) : []
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Canvas { context, size in
                                draw(&context, size: size, t: t, skip: Set(glass))
                            }
                            if !glass.isEmpty, #available(iOS 26, *) {
                                GlassPieces(run: run, indices: glass, t: t, size: geo.size)
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: TimeInterval, skip: Set<Int>) {
        let image = context.resolve(Image(uiImage: run.image))
        let w = size.width / CGFloat(run.cols), h = size.height / CGFloat(run.rows)
        let f = Shatter.frostColor
        let tint = Color(red: f.r, green: f.g, blue: f.b)
        let glassy = run.style == .glass
        for i in Shatter.drawOrder(run.tiles, at: t) where !skip.contains(i) {
            let tile = run.tiles[i]
            let p = Shatter.fall(tile, at: t)
            let opacity = Shatter.opacity(fall: p)
            if opacity <= 0 { continue }
            let frost = Shatter.frost(tile, at: t)
            let rect = CGRect(x: CGFloat(tile.col) * w, y: CGFloat(tile.row) * h, width: w, height: h)
            let flying = p > 0
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: rect.midX + Shatter.leafX(tile, fall: p),
                                  y: rect.midY + Shatter.leafY(fall: p, height: size.height))
                layer.rotate(by: .degrees(Shatter.leafRotation(tile, fall: p)))
                layer.translateBy(x: -rect.midX, y: -rect.midY)
                let shape = glassy && flying
                    ? Path(roundedRect: rect, cornerRadius: Shatter.glassCornerRadius) : Path(rect)
                layer.drawLayer { piece in
                    piece.clip(to: shape)
                    piece.draw(image, in: CGRect(origin: .zero, size: size))
                }
                guard frost > 0 else { return }
                if glassy {
                    Self.glassRim(&layer, rect: rect, corner: tile.corner, amount: frost, flying: flying)
                } else {
                    layer.fill(Path(rect), with: .color(tint.opacity(f.opacity * frost)))
                    layer.stroke(Self.perimeter(rect, from: tile.corner).trimmedPath(from: 0, to: frost),
                                 with: .color(.white.opacity(0.95)), lineWidth: 0.8)
                }
            }
        }
    }

    /// `.glass` in the Canvas: a sheen across the square and a bright rim growing round it from the seed's corner,
    /// in the frost's wave. In flight (a square past the glass cap) a fuller highlight, so it reads like the real glass.
    private static func glassRim(_ layer: inout GraphicsContext, rect: CGRect, corner: Int, amount g: Double, flying: Bool) {
        let tl = CGPoint(x: rect.minX, y: rect.minY), br = CGPoint(x: rect.maxX, y: rect.maxY)
        let sheen = flying ? 0.22 : 0.14
        layer.fill(Path(roundedRect: rect, cornerRadius: Shatter.glassCornerRadius),
                   with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(sheen * g), location: 0),
                                                          .init(color: .white.opacity(0.02 * g), location: 0.5),
                                                          .init(color: .white.opacity(sheen * 0.5 * g), location: 1)]),
                                         startPoint: tl, endPoint: br))
        let rim = flying ? Path(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), cornerRadius: Shatter.glassCornerRadius)
                         : perimeter(rect.insetBy(dx: 0.4, dy: 0.4), from: corner).trimmedPath(from: 0, to: g)
        layer.stroke(rim, with: .linearGradient(Gradient(colors: [.white.opacity(0.9 * g), .white.opacity(0.2 * g),
                                                                  .white.opacity(0.55 * g)]),
                                                startPoint: tl, endPoint: br),
                     lineWidth: 0.5 + 0.7 * g)
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

/// The real-glass squares: each its own crop as content, `.glassEffect(.regular)` in a 3 pt rounded rect, all in
/// ONE GlassEffectContainer (GlassBench: one container holds, one effect per square stutters past ~60).
@available(iOS 26, *)
private struct GlassPieces: View {
    let run: ShatterDirector.Run
    let indices: [Int]
    let t: TimeInterval
    let size: CGSize

    var body: some View {
        let w = size.width / CGFloat(run.cols), h = size.height / CGFloat(run.rows)
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(indices, id: \.self) { i in
                    let tile = run.tiles[i]
                    let p = Shatter.fall(tile, at: t)
                    piece(run.crops.indices.contains(i) ? run.crops[i] : nil)
                        .frame(width: w, height: h)
                        .glassEffect(.regular, in: .rect(cornerRadius: Shatter.glassCornerRadius))
                        .rotationEffect(.degrees(Shatter.leafRotation(tile, fall: p)))
                        .position(x: (CGFloat(tile.col) + 0.5) * w + Shatter.leafX(tile, fall: p),
                                  y: (CGFloat(tile.row) + 0.5) * h + Shatter.leafY(fall: p, height: size.height))
                        .opacity(Shatter.opacity(fall: p))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder private func piece(_ crop: UIImage?) -> some View {
        if let crop {
            Image(uiImage: crop).resizable().opacity(0.88)
                .clipShape(.rect(cornerRadius: Shatter.glassCornerRadius))
        } else {
            Color.clear
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
