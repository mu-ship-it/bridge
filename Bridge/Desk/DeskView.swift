import SwiftUI

/// 值班台 / Desk: the full-screen board for a phone parked on a desk. Clock, room, weather,
/// and what wants attention. Boring Box: black, white, one red; portrait and landscape.
struct DeskView: View {
    @Bindable private var desk = DeskStation.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var brightness = DeskBrightness()
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .topTrailing) {
                Theme.background.ignoresSafeArea()
                if landscape {
                    HStack(alignment: .top, spacing: Theme.Space.s24) {
                        VStack(alignment: .leading, spacing: Theme.Space.s16) {
                            ClockTile()
                            tileRow
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        attentionTile.frame(width: geo.size.width * 0.38)
                        // Its own column: an overlay here would sit on the Attention tile's corner.
                        exitButton
                    }
                    .padding(Theme.Space.s16)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.s16) {
                        ClockTile()
                        tileRow
                        attentionTile
                    }
                    .padding(Theme.Space.s16)
                    // Portrait: the corner above the clock is empty.
                    exitButton
                }
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.text)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await desk.runPayload() }
        .task { await desk.runClimate() }
        // Bright when Mu is at the desk, dim when not; re-checked every second so a stale
        // presence report or a new item's 30 s takes effect on time.
        .task {
            brightness.begin()
            while !Task.isCancelled {
                brightness.apply(desk.brightness())
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { brightness.end() } else if phase == .active { brightness.begin() }
        }
        .onDisappear { brightness.end() }
    }

    // MARK: Tiles

    /// Room, Weather and Muster side by side, one height. Room and Weather take a fixed share;
    /// Muster, which lists lanes, gets the rest.
    private var tileRow: some View {
        let gap = Theme.Space.s12
        let side: CGFloat? = rowWidth > 0 ? ((rowWidth - 2 * gap) * 0.28).rounded(.down) : nil
        return HStack(alignment: .top, spacing: gap) {
            roomTile.frame(width: side)
            weatherTile.frame(width: side)
            musterTile
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var musterTile: some View {
        let tile = desk.muster
        return DeskTile(label: "Lanes") {
            if tile.isEmpty {
                Text("no lanes").font(Theme.Role.body).foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    ForEach(tile.lanes) { MusterLaneRow(lane: $0) }
                    if tile.hidden > 0 {
                        Text("+\(tile.hidden)").font(Theme.Role.meta.bold()).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }

    private var roomTile: some View {
        DeskTile(label: "Room") {
            Text(desk.climate.temperature).font(Theme.Role.reading).lineLimit(1).minimumScaleFactor(0.4)
            Label {
                Text(desk.climate.humidity).font(Theme.Role.subhead.bold()).monospacedDigit()
            } icon: {
                Image(systemName: "humidity.fill")
            }
            .accessibilityLabel(Text("Humidity \(desk.climate.humidity)"))
            Text(desk.climate.sensor ?? desk.climateError ?? String(localized: "No sensor"))
                .font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(3)
        }
    }

    private var weatherTile: some View {
        let tile = WeatherTile(desk.payload?.weather)
        return DeskTile(label: "Weather") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(tile.temperature).font(Theme.Role.reading).lineLimit(1).minimumScaleFactor(0.4)
                Image(systemName: tile.symbol).font(Theme.Role.section).accessibilityHidden(true)
            }
            // The tile shares its row with Lanes: wrap rather than cut words off.
            Text(tile.summary.localizedForDisplay).font(Theme.Role.subhead.bold())
                .lineLimit(2).minimumScaleFactor(0.8)
            HStack(spacing: Theme.Space.s4) {
                Text(tile.range)
                if tile.stale { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
                    .accessibilityLabel(Text("stale")) }
            }
            .font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
            if let place = tile.place {
                Text(place).font(Theme.Role.meta).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private var attentionTile: some View {
        DeskTile(label: "Attention", badge: desk.attention.isEmpty ? nil : desk.attention.count) {
            if desk.attention.isEmpty {
                Label("Nothing needs you", systemImage: "checkmark.square")
                    .font(Theme.Role.body).foregroundStyle(Theme.dim)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        ForEach(desk.attention) { item in
                            AttentionRow(item: item, highlighted: desk.highlighted.contains(item.id)) {
                                Task { await desk.acknowledge(item) }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let error = desk.payloadError {
                Label(error, systemImage: "xmark.square.fill")
                    .font(Theme.Role.meta).foregroundStyle(Theme.red).lineLimit(2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Back to the tabs. Small and in the corner: the desk is for reading, not tapping.
    private var exitButton: some View {
        Button {
            desk.showing = false
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(Theme.Role.body)
                .foregroundStyle(Theme.dim)
                .padding(Theme.Space.s12)
        }
        .accessibilityLabel(Text("Leave desk"))
    }
}

/// Tile 1: big clock and the date, in the phone's locale and time zone.
private struct ClockTile: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: Theme.Space.s0) {
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.Role.clock)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(Theme.Role.section.bold())
                    .foregroundStyle(Theme.dim)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// One lane: its colour block, name, host and state word, then the clock bar (time used /
/// expected) drawn by the Board widget's own BoardBar — red and full when over.
private struct MusterLaneRow: View {
    let lane: MusterTile.Lane

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            // One line when it fits; otherwise the state word goes under the name, never cut short.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
                    name
                    Spacer(minLength: Theme.Space.s4)
                    stateWord
                }
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    name
                    stateWord
                }
            }
            BoardBar(row: lane.row)
            HStack(spacing: Theme.Space.s4) {
                if let host = lane.host { Text(host).foregroundStyle(Theme.dim) }
                Spacer(minLength: 0)
                if let clock = lane.clock {
                    Text(clock)
                        .bold(lane.isOver)
                        .foregroundStyle(lane.isOver ? Theme.red : Theme.text)
                }
            }
            .font(Theme.Role.meta)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
            Rectangle().fill(lane.rgb.map { Color(hex: $0) } ?? Theme.text)
                .frame(width: Theme.Space.s12, height: Theme.Space.s12)
                .accessibilityHidden(true)
            Text(lane.name).font(Theme.Role.widgetBody.bold()).lineLimit(1)
                .foregroundStyle(lane.row.isMuted ? Theme.dim : Theme.text)
        }
    }

    @ViewBuilder private var stateWord: some View {
        if let state = lane.state {
            HStack(spacing: Theme.Space.s4) {
                if let symbol = BoardStyle.symbol(for: lane.row.state) {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(state.localizedForDisplay).textCase(.uppercase)
            }
            .font(Theme.Role.label)
            .foregroundStyle(lane.isOver ? Theme.red : Theme.dim)
            .fixedSize()
        }
    }
}

/// A tile: uppercase label over a 1px outline.
private struct DeskTile<Content: View>: View {
    let label: LocalizedStringKey
    var badge: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                Text(label).boxLabel()
                if let badge {
                    Text("\(badge)").font(Theme.Role.meta.bold())
                        .padding(.horizontal, Theme.Space.s4)
                        .background(Theme.red).foregroundStyle(Theme.text)
                }
            }
            content
        }
        .padding(Theme.Space.s12)
        // Fills whatever height its row gives it, so tiles side by side share one outline height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: Theme.hairline))
    }
}

/// One attention item. Warnings carry a red bar *and* a triangle (shape, not just colour);
/// a new item is drawn inverted until its highlight runs out. Tap the check to clear it.
private struct AttentionRow: View {
    let item: DeskPayload.Item
    let highlighted: Bool
    let acknowledge: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s8) {
            Image(systemName: item.isWarning ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(item.isWarning ? Theme.Role.body : Theme.Role.meta)
                .foregroundStyle(item.isWarning ? Theme.red : (highlighted ? Theme.background : Theme.dim))
                .accessibilityLabel(Text(item.isWarning ? "Warning" : "Note"))
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                if let title = item.title { Text(title).font(Theme.Role.body.bold()).lineLimit(1) }
                Text(item.text).font(Theme.Role.body).lineLimit(3)
                if let date = ISO.date(item.ts) {
                    Text(date, format: .dateTime.hour().minute()).font(Theme.Role.meta)
                        .foregroundStyle(highlighted ? Theme.background : Theme.dim)
                }
            }
            Spacer(minLength: 0)
            Button(action: acknowledge) {
                Image(systemName: "checkmark.square").font(Theme.Role.section)
            }
            .accessibilityLabel(Text("Clear"))
        }
        .padding(Theme.Space.s8)
        .foregroundStyle(highlighted ? Theme.background : Theme.text)
        .background(highlighted ? Theme.text : Theme.background)
        .overlay(alignment: .leading) {
            if item.isWarning { Rectangle().fill(Theme.red).frame(width: Theme.Space.s4) }
        }
        .animation(.easeOut(duration: 0.3), value: highlighted)
    }
}
