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

enum BoardStyle {
    static let stripe: CGFloat = 4
    static let barHeight: CGFloat = 6
    static let muted = Color(hex: 0x5a5a5a)

    static func color(of row: Board.Row) -> Color {
        if row.state == .over { return Theme.red }
        if row.isMuted { return muted }
        return row.rgb.map { Color(hex: $0) } ?? Theme.text
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Header right side: STALE badge past 180 s, else the age; "+N" when rows were left out.
private struct BoardStamp: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: BoardSnapshot
    let date: Date
    var hidden = 0

    var body: some View {
        HStack(spacing: 6) {
            if hidden > 0 {
                Text("+\(hidden)").font(Theme.mono(.caption2, weight: .bold)).foregroundStyle(Theme.dim)
            }
            let age = BoardStyle.age(snapshot.age(at: date))
            if snapshot.isStale(at: date) {
                Text("STALE \(age)")
                    .font(Theme.label(.caption2)).tracking(Theme.labelTracking)
                    .foregroundStyle(mode == .fullColor ? Theme.background : Theme.text)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(mode == .fullColor ? Theme.red : .clear)
                    .overlay(Rectangle().strokeBorder(mode == .fullColor ? .clear : Theme.text, lineWidth: 1))
                    .widgetAccentable()
            } else {
                Text(age).font(Theme.mono(.caption2)).foregroundStyle(Theme.dim)
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
                    Rectangle().strokeBorder(Theme.dim, lineWidth: 1)
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
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(BoardStyle.color(of: row))
                .frame(width: BoardStyle.stripe)
                .widgetAccentable(!row.isMuted)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.label)
                        .font(.system(compact ? .caption : .subheadline, weight: .heavy))
                        .foregroundStyle(row.isMuted ? Theme.dim : Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let value = row.value, !value.isEmpty {
                        Text(value)
                            .font(Theme.mono(.caption, weight: row.state == .over ? .heavy : .medium))
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

private struct BoardHeading: View {
    let title: String
    var body: some View {
        Text(title).boxLabel().padding(.top, 2)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.board.title ?? snapshot.name).boxLabel(.caption, color: Theme.text)
                Spacer()
                BoardStamp(snapshot: snapshot, date: date, hidden: hidden)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            if parts.allSatisfy({ $0.lines.isEmpty }) {
                Text("Empty board.").font(.subheadline).foregroundStyle(Theme.dim)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(parts.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 8) {
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
                        Rectangle().fill(Theme.line).frame(width: 1)
                    }
                }
            }
            Spacer(minLength: 0)
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
        VStack(alignment: .leading, spacing: 2) {
            if stale {
                Text("STALE \(BoardStyle.age(snapshot.age(at: date)))")
                    .font(Theme.label(.caption2)).tracking(Theme.labelTracking).lineLimit(1)
            }
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 4) {
                    Text(row.label).font(.system(.caption2, weight: .heavy)).lineLimit(1)
                        .frame(width: 44, alignment: .leading)
                    BoardBar(row: row, height: 4)
                    Text(row.value ?? "").font(Theme.mono(.caption2)).lineLimit(1)
                        .frame(maxWidth: 60, alignment: .trailing)
                }
            }
            if rows.isEmpty {
                Text(snapshot.board.title ?? snapshot.name).font(.headline).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoardEmpty: View {
    let name: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).boxLabel(.caption, color: Theme.text)
            if !compact { Rectangle().fill(Theme.line).frame(height: 1) }
            Text("No board yet.").font(compact ? .caption : .subheadline)
            if !compact {
                Text("The box has nothing under “\(name)”, or 白手套 is not set up.")
                    .font(.caption).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
