import SwiftUI

/// "Boring Box": pure black, white text, 1px #2a2a2a lines, flat. One red, only for
/// running / error / badge. Heavy uppercase labels, monospaced numbers and ids. Shared by the
/// app and the widget extension.
enum Theme {
    static let background = Color.black
    static let text = Color.white
    /// Secondary copy: notes, footers, relative times.
    static let dim = Color(hex: 0x8a8a8a)
    static let line = Color(hex: 0x2a2a2a)
    /// Stale status square, disabled glyphs.
    static let stale = Color(hex: 0x3a3a3a)
    /// The only accent. Running, error, badge — nothing else.
    static let red = Color(hex: 0xff2d20)

    static let squareSize: CGFloat = 8
    static let labelTracking: CGFloat = 1.2

    /// Numbers, ids, times.
    static func mono(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Heavy uppercase label font (pair with `.boxLabel()` for case + tracking).
    static func label(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, weight: .heavy)
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
    /// Heavy, uppercase, letter-spaced. "ACTIVITY · 动态".
    func boxLabel(_ style: Font.TextStyle = .caption2, color: Color = Theme.dim) -> some View {
        font(Theme.label(style))
            .textCase(.uppercase)
            .tracking(Theme.labelTracking)
            .foregroundStyle(color)
    }
}

/// The 8pt status square: white = done, red = running or failed, #3a3a3a = stale.
struct StatusSquare: View {
    enum State: String { case done, running, failed, stale }
    let state: State
    /// 1pt outline instead of a fill: the widget's tinted and lock-screen modes, where a
    /// filled square flattens into a solid block.
    var outlined = false

    var body: some View {
        Group {
            if outlined {
                Rectangle().strokeBorder(color, lineWidth: 1)
            } else {
                Rectangle().fill(color)
            }
        }
        .frame(width: Theme.squareSize, height: Theme.squareSize)
        .accessibilityLabel(Text(state.rawValue))
    }

    /// A #3a3a3a outline all but vanishes once the system tints by luminance; dim instead.
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
            .font(Theme.label(.caption2))
            .textCase(.uppercase)
            .tracking(Theme.labelTracking)
            .foregroundStyle(selected ? Theme.background : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Theme.text : Theme.background)
            .overlay(Rectangle().strokeBorder(selected ? Theme.text : Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
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
