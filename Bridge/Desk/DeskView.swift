import SwiftUI

/// 值班台 / Desk: the full-screen board for a phone parked on a desk. Room, weather, lanes
/// and what wants attention (a nixie clock sits next to the phone, so the date is all the time). Boring Box: black, white, one red; portrait and landscape.
struct DeskView: View {
    @Bindable private var desk = DeskStation.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var brightness = DeskBrightness()
    @State private var shift = LayoutShift.offset(slot: LayoutShift.slot(at: Date()))

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let attentionHeight = AttentionSizing.height(items: max(desk.attention.count, desk.payloadError == nil ? 0 : 1), screen: geo.size.height)
            let m = DeskMetrics.make(size: geo.size)
            VStack(alignment: .leading, spacing: m.gap) {
                topBar.frame(height: m.topBarHeight)
                tiles(landscape: landscape, gap: m.gap, padding: m.tilePadding)
                    .frame(maxHeight: .infinity)
                if attentionHeight > 0 {
                    attentionTile(padding: m.tilePadding).frame(height: attentionHeight)
                }
            }
            .padding(m.margin)
            .offset(x: CGFloat(shift.x), y: CGFloat(shift.y))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .animation(.easeInOut(duration: 0.4), value: attentionHeight)
            .animation(.easeInOut(duration: 0.4), value: desk.muster.lanes.count)
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.text)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await desk.runPayload() }
        .task { await desk.runClimate() }
        // Burn-in guard: a new place every 3 minutes, moved over 1 s.
        .task {
            while !Task.isCancelled {
                let now = Date()
                withAnimation(.easeInOut(duration: 1)) {
                    let o = LayoutShift.offset(slot: LayoutShift.slot(at: now))
                    shift = (o.x, o.y)
                }
                let wait = LayoutShift.nextChange(after: now).timeIntervalSince(now)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
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

    /// Date on the left; weather one-liner and the exit button on the right.
    private var topBar: some View {
        HStack(spacing: Theme.Space.s12) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(Theme.Role.body.bold()).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s8)
            weatherLine
            exitButton
        }
    }

    /// "9° ☀ Clear sky   -1° / 14° · Shenyang": the long form first, shorter ones when the row is narrow.
    private var weatherLine: some View {
        let tile = WeatherTile(desk.payload?.weather)
        let temp = Text(tile.temperature).font(Theme.Role.section.bold()).monospacedDigit()
        let symbol = Image(systemName: tile.symbol).font(Theme.Role.body).accessibilityHidden(true)
        let summary = Text(tile.summary.localizedForDisplay).font(Theme.Role.body.bold())
        let rangeText = tile.place.map { "\(tile.range) · \($0)" } ?? tile.range
        let detail = HStack(spacing: Theme.Space.s4) {
            Text(rangeText)
            if tile.stale { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
                .accessibilityLabel(Text("stale")) }
        }
        .font(Theme.Role.data).foregroundStyle(Theme.dim)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s8) { temp; symbol; summary; detail }
            HStack(spacing: Theme.Space.s8) { temp; symbol; summary }
            HStack(spacing: Theme.Space.s8) { temp; symbol }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Room and Lanes: side by side in landscape, stacked in portrait. With no lanes Room is alone,
    /// full width.
    @ViewBuilder private func tiles(landscape: Bool, gap: CGFloat, padding: CGFloat) -> some View {
        let lanes = DeskRow.showsLanes(laneCount: desk.muster.lanes.count)
        if !lanes {
            roomTile(padding, alone: true)
        } else if landscape {
            HStack(alignment: .top, spacing: gap) {
                roomTile(padding, alone: false)
                musterTile(padding).transition(.opacity)
            }
        } else {
            VStack(spacing: gap) {
                roomTile(padding, alone: false)
                musterTile(padding).transition(.opacity)
            }
        }
    }

    private func musterTile(_ padding: CGFloat) -> some View {
        let tile = desk.muster
        return DeskTile(label: "Lanes", padding: padding) { _ in
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

    private func roomTile(_ padding: CGFloat, alone: Bool) -> some View {
        DeskTile(label: "Room", padding: padding) { size in
            let climate = desk.roomClimate
            let temp = Text(climate.temperature)
                .font(.system(size: DeskMetrics.readingSize(tile: size, alone: alone), weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.4)
            let humidity = Label {
                Text(climate.humidity).font(Theme.Role.section.bold()).monospacedDigit()
            } icon: {
                Image(systemName: "humidity.fill")
            }
            .accessibilityLabel(Text("Humidity \(climate.humidity)"))
            let sensor = Text(climate.sensor ?? desk.climateError ?? String(localized: "No sensor"))
                .font(Theme.Role.data).foregroundStyle(Theme.dim).lineLimit(3)
            if alone {
                HStack(alignment: .center, spacing: Theme.Space.s24) {
                    temp
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        humidity
                        comfortLine(climate)
                        sensor
                    }
                }
            } else {
                temp
                humidity
                comfortLine(climate)
                sensor
            }
        }
    }

    @ViewBuilder private func comfortLine(_ climate: ClimateTile) -> some View {
        let comfort = ComfortPolicy.assess(tempC: climate.celsius, humidity: climate.humidityPercent)
        if let word = comfort.word {
            HStack(spacing: Theme.Space.s8) {
                Text(LocalizedStringKey(word)).font(Theme.Role.section.bold())
                    .foregroundStyle(Self.comfortColor(comfort))
                if let feels = ComfortPolicy.feelsLike(tempC: climate.celsius, humidity: climate.humidityPercent) {
                    Text("feels \(feels)°").font(Theme.Role.data).foregroundStyle(Theme.dim)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private static func comfortColor(_ comfort: Comfort) -> Color {
        switch comfort {
        case .chilly, .dry: Color(hex: 0xffb020)
        case .warm, .humid: Color(hex: 0xff5a1f)
        case .comfortable, .unknown: Theme.dim
        }
    }

    @ViewBuilder private func attentionTile(padding: CGFloat) -> some View {
        DeskTile(label: "Attention", padding: padding, badge: desk.attention.isEmpty ? nil : desk.attention.count) { _ in
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
            if let error = desk.payloadError {
                Label(error, systemImage: "xmark.square.fill")
                    .font(Theme.Role.meta).foregroundStyle(Theme.red).lineLimit(2)
            }
        }
    }

    /// Back to the tabs. Small and in the corner: the desk is for reading, not tapping.
    private var exitButton: some View {
        Button {
            desk.showing = false
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(Theme.Role.body)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, Theme.Space.s8)
        }
        .accessibilityLabel(Text("Leave desk"))
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
            .font(Theme.Role.data)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
            Rectangle().fill(lane.rgb.map { Color(hex: $0) } ?? Theme.text)
                .frame(width: Theme.Space.s12, height: Theme.Space.s12)
                .accessibilityHidden(true)
            Text(lane.name).font(Theme.Role.body.bold()).lineLimit(1)
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
    let padding: CGFloat
    var badge: Int?
    /// Gets the tile's inner size, so big readings scale with the tile.
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            inner(CGSize(width: geo.size.width - 2 * padding, height: geo.size.height - 2 * padding))
        }
    }

    private func inner(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                Text(label).boxLabel()
                if let badge {
                    Text("\(badge)").font(Theme.Role.meta.bold())
                        .padding(.horizontal, Theme.Space.s4)
                        .background(Theme.red).foregroundStyle(Theme.text)
                }
            }
            content(size)
        }
        .padding(padding)
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
