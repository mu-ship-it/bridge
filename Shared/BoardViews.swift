import SwiftUI
import WidgetKit

extension View {
    /// Black in light mode too: an explicit background, and a dark scheme so system text is white.
    /// Every widget's container, on iOS and macOS.
    func boxWidgetContainer() -> some View {
        foregroundStyle(Theme.text)
            .environment(\.colorScheme, .dark)
            .containerBackground(Theme.background, for: .widget)
    }
}

/// The board widgets' views, shared by the iOS and macOS widget extensions. Boring Box, louder:
/// black, a hard colour stripe per row, one thick flat bar, no rounding, no material.
struct BoardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let name: String
    let snapshot: BoardSnapshot?
    let date: Date

    var body: some View {
        if let snapshot {
            switch family {
            #if !os(macOS)
            case .accessoryRectangular: BoardRectangular(snapshot: snapshot, date: date)
            #endif
            case .systemExtraLarge: BoardPanel(snapshot: snapshot, date: date, limit: 9, columns: 2)
            case .systemLarge: BoardPanel(snapshot: snapshot, date: date, limit: 9, columns: 1)
            default: BoardPanel(snapshot: snapshot, date: date, limit: 3, columns: 1, headings: false)
            }
        } else {
            BoardEmpty(name: name, compact: isAccessory)
        }
    }
}

extension BoardWidgetView {
    private var isAccessory: Bool {
        #if os(macOS)
        false
        #else
        family == .accessoryRectangular
        #endif
    }
}

/// A rule (hairline) that stays visible in tinted and lock-screen modes, where #2a2a2a vanishes.
struct BoxRule: View {
    @Environment(\.widgetRenderingMode) private var mode
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(mode == .fullColor ? Theme.line : Theme.dim)
            .frame(width: vertical ? Theme.hairline : nil, height: vertical ? nil : Theme.hairline)
    }
}

/// Preview canvases only (Xcode previews render views outside a widget container).
enum WidgetPreview {
    static let medium = CGSize(width: 364, height: 170)
}

enum BoardStyle {
    static let stripe = Theme.Space.s4
    static let barHeight = Theme.Space.s8

    static func color(of row: Board.Row) -> Color {
        if row.state == .over { return Theme.red }
        if row.isMuted { return Theme.muted }
        return row.rgb.map { Color(hex: $0) } ?? Theme.text
    }

    /// A row's state as a shape, so it reads without colour (tinted, lock screen). `ok` has none.
    static func symbol(for state: Board.Row.State?) -> String? {
        switch state {
        case .over: "exclamationmark.triangle.fill"
        case .stalled: "pause.fill"
        case .idle: "moon.zzz.fill"
        case .ok, nil: nil
        }
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return String(localized: "\(s)s", comment: "Age in seconds, compact") }
        if s < 3600 { return String(localized: "\(s / 60)m", comment: "Age in minutes, compact") }
        if s < 86400 { return String(localized: "\(s / 3600)h", comment: "Age in hours, compact") }
        return String(localized: "\(s / 86400)d", comment: "Age in days, compact")
    }
}

/// Header right side: STALE badge past 180 s, else the age; "+N" when rows were left out.
private struct BoardStamp: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: BoardSnapshot
    let date: Date
    var hidden = 0

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            if hidden > 0 {
                Text("+\(hidden)").font(Theme.Role.meta.bold()).foregroundStyle(Theme.dim)
            }
            let age = BoardStyle.age(snapshot.age(at: date))
            if snapshot.isStale(at: date) {
                Text("STALE \(age)")
                    .font(Theme.Role.label).monospacedDigit().tracking(Theme.labelTracking)
                    .foregroundStyle(mode == .fullColor ? Theme.background : Theme.text)
                    .padding(.horizontal, Theme.Space.s4)
                    .background(mode == .fullColor ? Theme.red : .clear)
                    .overlay(Rectangle().strokeBorder(mode == .fullColor ? .clear : Theme.text, lineWidth: Theme.hairline))
                    .widgetAccentable()
            } else {
                Text(age).font(Theme.Role.meta).foregroundStyle(Theme.dim)
            }
        }
        .lineLimit(1)
    }
}

/// One thick bar: track, faded layer (`bar_faded`), solid fill (`bar`). Over → full red.
struct BoardBar: View {
    @Environment(\.widgetRenderingMode) private var mode
    let row: Board.Row
    var height: CGFloat = BoardStyle.barHeight

    var body: some View {
        let color = BoardStyle.color(of: row)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if mode == .fullColor {
                    Rectangle().fill(Theme.line)
                } else {
                    Rectangle().strokeBorder(Theme.dim, lineWidth: Theme.hairline)
                }
                Rectangle().fill(color.opacity(0.35))
                    .frame(width: geo.size.width * row.fadedFill)
                Rectangle().fill(color)
                    .frame(width: geo.size.width * row.fill)
                    .widgetAccentable(!row.isMuted)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct BoardRowView: View {
    let row: Board.Row

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            Rectangle().fill(BoardStyle.color(of: row))
                .frame(width: BoardStyle.stripe)
                .widgetAccentable(!row.isMuted)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                    Text(row.label)
                        .font(Theme.Role.widgetBody.bold())
                        .foregroundStyle(row.isMuted ? Theme.dim : Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    BoardStateMark(row: row)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail).font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.s4)
                    if let value = row.value, !value.isEmpty {
                        Text(value)
                            .font(row.state == .over ? Theme.Role.data.bold() : Theme.Role.data)
                            .foregroundStyle(row.state == .over ? Theme.red : Theme.text)
                            .lineLimit(1)
                            .layoutPriority(2)
                            .widgetAccentable(row.state == .over)
                    }
                }
                BoardBar(row: row)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// The state's symbol next to the lane's name (nothing for `ok`).
struct BoardStateMark: View {
    let row: Board.Row

    var body: some View {
        if let symbol = BoardStyle.symbol(for: row.state), let state = row.state {
            Image(systemName: symbol)
                .font(Theme.Role.meta)
                .foregroundStyle(BoardStyle.color(of: row))
                .widgetAccentable(state == .over)
                .accessibilityLabel(Text(state.rawValue.localizedForDisplay))
        }
    }
}

private struct BoardHeading: View {
    let title: String
    var body: some View {
        Text(title).boxLabel().padding(.top, Theme.Space.s4)
    }
}

/// Medium, large and extra large: header, rule, rows (in columns on extra large).
private struct BoardPanel: View {
    let snapshot: BoardSnapshot
    let date: Date
    let limit: Int
    let columns: Int
    var headings = true

    var body: some View {
        let parts = snapshot.board.columns(columns).map { $0.lines(limit: limit, headings: headings) }
        let hidden = parts.reduce(0) { $0 + $1.hidden }
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.board.title ?? snapshot.name).boxLabel(color: Theme.text)
                Spacer()
                BoardStamp(snapshot: snapshot, date: date, hidden: hidden)
            }
            BoxRule()
            if parts.allSatisfy({ $0.lines.isEmpty }) {
                Text("Empty board.").font(Theme.Role.widgetBody).foregroundStyle(Theme.dim)
            }
            HStack(alignment: .top, spacing: Theme.Space.s16) {
                ForEach(parts.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        ForEach(parts[column].lines.indices, id: \.self) { index in
                            switch parts[column].lines[index] {
                            case .heading(let title): BoardHeading(title: title)
                            case .row(let row):
                                if let url = BoardRoute.url(for: row.url) {
                                    Link(destination: url) { BoardRowView(row: row) }
                                } else {
                                    BoardRowView(row: row)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if column < parts.count - 1 {
                        BoxRule(vertical: true)
                    }
                }
            }
            Spacer(minLength: Theme.Space.s0)
        }
    }
}

/// Lock screen / tinted accessory: three compact lines, label · bar · value.
private struct BoardRectangular: View {
    let snapshot: BoardSnapshot
    let date: Date

    var body: some View {
        let stale = snapshot.isStale(at: date)
        let rows = snapshot.board.sections.flatMap(\.rows).prefix(stale ? 2 : 3)
        VStack(alignment: .leading, spacing: Theme.Space.s0) {
            if stale {
                Text("STALE \(BoardStyle.age(snapshot.age(at: date)))")
                    .font(Theme.Role.label).monospacedDigit().tracking(Theme.labelTracking).lineLimit(1)
            }
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: Theme.Space.s4) {
                    HStack(spacing: Theme.Space.s0) {
                        Text(row.label).font(Theme.Role.label).lineLimit(1)
                        BoardStateMark(row: row)
                    }
                    .frame(width: Theme.Space.s48, alignment: .leading)
                    BoardBar(row: row, height: Theme.Space.s4)
                    Text(row.value ?? "").font(Theme.Role.meta).lineLimit(1)
                        .frame(maxWidth: Theme.Space.s64, alignment: .trailing)
                }
            }
            if rows.isEmpty {
                Text(snapshot.board.title ?? snapshot.name).font(Theme.Role.widgetBody.bold()).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoardEmpty: View {
    let name: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(name).boxLabel(color: Theme.text)
            if !compact { BoxRule() }
            Text("No board yet.").font(compact ? Theme.Role.meta : Theme.Role.widgetBody)
            if !compact {
                Text("The box has nothing under “\(name)”, or 白手套 is not set up.")
                    .font(Theme.Role.meta).foregroundStyle(Theme.dim)
                Spacer(minLength: Theme.Space.s0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
