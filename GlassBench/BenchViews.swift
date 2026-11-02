import SwiftUI

struct BenchRoot: View {
    let bench: Bench

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            DeskPicture().ignoresSafeArea()
            GeometryReader { geo in
                Squares(bench: bench, size: geo.size)
            }
            .ignoresSafeArea()
            Overlay(bench: bench)
            if !bench.glassAvailable { FallbackBanner(bench: bench) }
            if bench.isFinished { ResultsTable(bench: bench) }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DeskPicture: View {
    var body: some View {
        ZStack {
            Text("22°").font(.system(size: 190, weight: .thin)).foregroundStyle(.white).offset(x: -150, y: 10)
            RoundedRectangle(cornerRadius: 22).fill(Color.orange).frame(width: 170, height: 90).offset(x: 130, y: -90)
            RoundedRectangle(cornerRadius: 22).fill(Color.teal).frame(width: 220, height: 70).offset(x: 190, y: 40)
            RoundedRectangle(cornerRadius: 14).fill(Color.pink).frame(width: 120, height: 120).offset(x: 40, y: 80)
            Circle().stroke(Color.green, lineWidth: 14).frame(width: 130, height: 130).offset(x: 290, y: -60)
            Circle().stroke(Color.yellow, lineWidth: 10).frame(width: 90, height: 90).offset(x: -40, y: -100)
            Circle().stroke(Color.blue, lineWidth: 18).frame(width: 170, height: 170).offset(x: -20, y: 40)
        }
    }
}

private struct Squares: View {
    let bench: Bench
    let size: CGSize

    var body: some View {
        let t = bench.time
        let n = bench.n
        if bench.phase == .container, bench.glassAvailable, #available(iOS 26, *) {
            GlassEffectContainer(spacing: 0) { field(t, n) }
        } else {
            field(t, n)
        }
    }

    private func field(_ t: TimeInterval, _ n: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<n, id: \.self) { i in
                let p = Leaf.pose(i, at: t, size: size)
                Square(own: bench.phase != .container)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(p.rot))
                    .opacity(p.opacity)
                    .offset(x: p.x, y: p.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct Square: View {
    let own: Bool
    var body: some View {
        if #available(iOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.ultraThinMaterial)
        }
    }
}

private struct Overlay: View {
    let bench: Bench

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("phase \(bench.phase.rawValue)")
            Text("N \(bench.n)   fps \(String(format: "%.1f", bench.fps))   worst \(String(format: "%.1f", bench.worstMs)) ms")
            Text("thermal \(bench.thermal)   batt \(bench.battery)")
            Text("t \(Int(bench.time)) s   iOS \(bench.osVersion)   \(bench.glassAvailable ? "glass" : "MATERIAL FALLBACK")")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white)
        .padding(4)
        .background(Color.black.opacity(0.6))
        .padding(.leading, 50).padding(.top, 6)
    }
}

private struct FallbackBanner: View {
    let bench: Bench
    var body: some View {
        VStack(spacing: 4) {
            Text("Liquid Glass needs iOS 26+ — this phone is iOS \(bench.osVersion)").font(.title2.bold())
            Text("Squares below are .ultraThinMaterial (fallback), NOT Liquid Glass").font(.footnote)
        }
        .padding(12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ResultsTable: View {
    let bench: Bench

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GlassBench results — iOS \(bench.osVersion)\(bench.glassAvailable ? "" : " (material fallback)")").font(.headline)
            ForEach(bench.results) { r in
                Text("\(r.name):  limit \(r.limit.map(String.init) ?? "≥\(Bench.maxN)")  —  \(r.reason)  —  worst \(String(format: "%.0f", r.worstMs)) ms  —  thermal \(r.thermal)")
            }
            Divider().overlay(.white.opacity(0.4))
            ForEach(Array(bench.samples.enumerated()), id: \.offset) { _, s in
                Text("\(s.phase.prefix(1))  N\(s.n)  \(String(format: "%.1f", s.fps)) fps  \(String(format: "%.0f", s.worstMs)) ms  \(s.thermal)")
                    .font(.system(size: 8, design: .monospaced))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92))
        .ignoresSafeArea()
    }
}
