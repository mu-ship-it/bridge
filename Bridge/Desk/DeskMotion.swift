import SwiftUI
import UIKit

/// The desk's few movements. Every one has a Reduce Motion form that is a plain crossfade.
enum DeskMotion {
    static var reduce: Bool { UIAccessibility.isReduceMotionEnabled }

    private static func pick(_ animation: Animation) -> Animation {
        reduce ? .easeInOut(duration: 0.25) : animation
    }

    static var laneIn: Animation { pick(.easeOut(duration: 0.4)) }
    static var laneOut: Animation { pick(.easeIn(duration: 0.3)) }
    static var itemIn: Animation { pick(.easeOut(duration: 0.35)) }
    static var itemOut: Animation { pick(.easeIn(duration: 0.3)) }
    static var bar: Animation { pick(.easeInOut(duration: 0.6)) }
    /// The lights-out: the layout slides away and back.
    static var lightsOut: Animation { pick(.easeInOut(duration: 0.6)) }
    static let face = Animation.easeInOut(duration: 0.15)
    static let flip = Animation.easeInOut(duration: 0.25)
    static let borderFlash = Animation.easeOut(duration: 0.5)

    /// A lane row: slides in from the left; leaves by collapsing its height and fading.
    static var laneTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: AnyTransition(CollapseTransition()))
    }

    /// An attention item: in and out through the right edge.
    static var itemTransition: AnyTransition {
        reduce ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// A changed clock digit pair turns over about its horizontal axis.
    static var flipTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: AnyTransition(Flip(angle: -90)), removal: AnyTransition(Flip(angle: 90)))
    }
}

private struct Flip: Transition {
    let angle: Double
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .rotation3DEffect(.degrees(phase.isIdentity ? 0 : angle), axis: (x: 1, y: 0, z: 0))
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// Height → 0 and opacity → 0, so the rows below close the gap as it shrinks.
private struct CollapseTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        CollapseLayout(fraction: phase.isIdentity ? 1 : 0) { content.opacity(phase.isIdentity ? 1 : 0) }.clipped()
    }
}

private struct CollapseLayout: Layout {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: size.width, height: size.height * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// "HH:mm" with only the pair that changed turning over.
struct FlipClock: View {
    let time: String
    let font: Font

    var body: some View {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        HStack(spacing: 0) {
            pair(parts.first ?? "")
            Text(":")
            pair(parts.count > 1 ? parts[1] : "")
        }
        .font(font)
        .lineLimit(1).fixedSize()
    }

    private func pair(_ text: String) -> some View {
        ZStack {
            Text(text).id(text).transition(DeskMotion.flipTransition)
        }
        .animation(DeskMotion.flip, value: text)
    }
}
