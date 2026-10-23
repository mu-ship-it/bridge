import SwiftUI

/// "Boring Box": pure black, white text, 1px #2a2a2a lines, flat. One red, only for
/// running / error / badge. Bold uppercase labels, monospaced numbers and ids. Shared by the
/// app and the widget extension.
enum Theme {
    static let background = Color.black
    static let text = Color.white
    /// Secondary copy: notes, footers, relative times.
    static let dim = Color(hex: 0x8a8a8a)
    static let line = Color(hex: 0x2a2a2a)
    /// Stale status square, disabled glyphs.
    static let stale = Color(hex: 0x3a3a3a)
    /// Stalled / idle board rows: grey, a step brighter than `stale` so a bar still reads.
    static let muted = Color(hex: 0x5a5a5a)
    /// The only accent. Running, error, badge — nothing else.
    static let red = Color(hex: 0xff2d20)
    /// A pressed button: one background step up, not transparency.
    static let pressed = Color(hex: 0x1a1a1a)

    /// Every gap, inset and fixed size is one of these. Nothing else is written.
    enum Space {
        static let s0: CGFloat = 0
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s48: CGFloat = 48
        static let s64: CGFloat = 64
        static let s96: CGFloat = 96
    }

    /// A rule or outline's line weight (not a space).
    static let hairline: CGFloat = 1

    static let labelTracking: CGFloat = 1.2

    /// Type roles. A surface picks a role; a role is a text style; no point size is written.
    /// Weights are the style's own, or `.bold` — never another.
    enum Role {
        static let display = Font.largeTitle
        static let title = Font.title
        static let section = Font.title2
        static let subhead = Font.title3
        /// Body copy on a screen.
        static let body = Font.body
        /// Body copy in a widget.
        static let widgetBody = Font.subheadline
        static let prose = Font.body
        /// Numbers, ids, values: monospaced, so figures line up.
        static let data = Font.system(.subheadline, design: .monospaced)
        /// Uppercased, tracked (`.boxLabel()`).
        static let label = Font.system(.caption2, weight: .bold)
        /// Times, ages, counts, one-line summaries.
        static let meta = Font.system(.caption2, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

extension View {
    /// The label role: bold, uppercase, letter-spaced. "ACTIVITY".
    func boxLabel(color: Color = Theme.dim) -> some View {
        font(Theme.Role.label)
            .textCase(.uppercase)
            .tracking(Theme.labelTracking)
            .foregroundStyle(color)
    }
}

/// A job's status as an SF Symbol square: the shape says the state (checked, playing, crossed,
/// dashed), so it survives tinted and lock-screen modes where colour does not; the colour (white
/// done, red running or failed, grey stale) is the signal on top. Sized by the surrounding text style.
struct StatusSquare: View {
    enum State: String { case done, running, failed, stale }
    let state: State
    /// Outline variants instead of filled: the widget's tinted and lock-screen modes, where a
    /// filled square flattens into a solid block.
    var outlined = false

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(Text(state.rawValue.localizedForDisplay))
    }

    var symbol: String {
        let base = switch state {
        case .done: "checkmark.square"
        case .running: "play.square"
        case .failed: "xmark.square"
        case .stale: "minus.square"
        }
        return outlined || state == .stale ? base : base + ".fill"
    }

    /// A #3a3a3a symbol all but vanishes once the system tints by luminance; dim instead.
    var color: Color { outlined && state == .stale ? Theme.dim : Self.color(for: state) }

    static func color(for state: State) -> Color {
        switch state {
        case .done: Theme.text
        case .running, .failed: Theme.red
        case .stale: Theme.stale
        }
    }
}

/// Flat outlined button: heavy uppercase label, 1px line, no fill.
struct BoxButtonStyle: ButtonStyle {
    var selected = false
    var color: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Role.label)
            .textCase(.uppercase)
            .tracking(Theme.labelTracking)
            .foregroundStyle(selected ? Theme.background : color)
            .padding(.horizontal, Theme.Space.s8)
            .padding(.vertical, Theme.Space.s4)
            .background(selected ? Theme.text : configuration.isPressed ? Theme.pressed : Theme.background)
            .overlay(Rectangle().strokeBorder(selected ? Theme.text : Theme.line, lineWidth: Theme.hairline))
    }
}

extension ButtonStyle where Self == BoxButtonStyle {
    static func box(selected: Bool = false, color: Color = Theme.text) -> BoxButtonStyle {
        BoxButtonStyle(selected: selected, color: color)
    }
}

extension View {
    /// A List or Form in the Boring Box look: black, flat, 1px lines.
    func boxList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .foregroundStyle(Theme.text)
    }

    /// Black row, #2a2a2a separators. Apply per Section.
    func boxRows() -> some View {
        listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.line)
            .listSectionSeparatorTint(Theme.line)
    }
}
