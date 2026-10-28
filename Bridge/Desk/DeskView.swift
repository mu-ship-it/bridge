import SwiftUI

/// 值班台 / Desk: the full-screen board for a phone parked on a desk. Room, weather, lanes
/// and what wants attention (a nixie clock sits next to the phone, so the date is all the time). Boring Box: black, white, one red; portrait and landscape.
struct DeskView: View {
    @Bindable private var desk = DeskStation.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var brightness = DeskBrightness()
    /// Burn-in protection (BurnIn): the layout steps to its next offset only at the hourly shatter;
    /// lights-out blanks it but for the face.
    @State private var shift = BurnIn.offset(at: Date())
    @State private var sweepHour = BurnIn.sweepHour(at: Date())
    @State private var shatterTick = 0
    @State private var shatter = ShatterDirector()
    @State private var lightsOut = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let m = DeskMetrics.make(size: geo.size)
            let state = DeskState.make(laneCount: desk.muster.lanes.count,
                                       attentionCount: max(desk.attention.count, desk.payloadError == nil ? 0 : 1))
            ZStack {
                sleepingFace.opacity(lightsOut ? 1 : 0)
                VStack(alignment: .leading, spacing: m.gap) {
                    topBar(weather: state.weatherInTopRow).frame(height: m.topBarHeight)
                    tiles(state, landscape: landscape, gap: m.gap, padding: m.tilePadding)
                        .frame(maxHeight: .infinity)
                    footer(m).frame(height: m.footerHeight)
                }
                .padding(m.margin)
                .offset(x: CGFloat(shift.x), y: CGFloat(shift.y))
                // Reduce Motion: the lights-out is a crossfade, not a slide.
                .offset(x: lightsOut && !DeskMotion.reduce ? -geo.size.width : 0)
                .opacity(lightsOut && DeskMotion.reduce ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .animation(.easeInOut(duration: 0.4), value: state)
            .animation(DeskMotion.lightsOut, value: lightsOut)
            .overlay { if let run = shatter.run { ShatterOverlay(run: run) } }
            .modifier(ShakeEffect(progress: shatter.shake))
            .onChange(of: shatterTick) { runShatter(size: geo.size) }
            .background(FingerTap(touches: 2) { desk.toggleLightsOut() })
            .background(FingerTap(touches: 3) { runShatter(size: geo.size) })
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
                desk.trackPresence()
                let now = Date()
                let hour = BurnIn.sweepHour(at: now)
                if hour != sweepHour { sweepHour = hour; shatterTick += 1 }
                lightsOut = BurnIn.lightsOut(at: now, manualSince: desk.lightsOutSince)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { brightness.end() } else if phase == .active { brightness.begin() }
        }
        .onDisappear { brightness.end() }
    }

    // MARK: Tiles

    private enum TopItem: Hashable { case date, spacer, weather, seats, exit }

    /// Date on the left, the seats one-liner, the exit button on the right; with Attention and Lanes both up,
    /// Weather's one-liner joins the row, left of the seats. The row gives up the weather, then the weekday,
    /// before it would cut anything short.
    @ViewBuilder private func topBar(weather: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            if weather {
                topRow([.date, .spacer, .weather, .seats, .exit], shortDate: false)
                topRow([.date, .spacer, .weather, .seats, .exit], shortDate: true)
            }
            topRow([.date, .spacer, .seats, .exit], shortDate: false)
            topRow([.date, .spacer, .seats, .exit], shortDate: true)
        }
    }

    private func topRow(_ items: [TopItem], shortDate: Bool) -> some View {
        HStack(spacing: Theme.Space.s12) {
            ForEach(items, id: \.self) { item in
                switch item {
                case .weather: weatherLine
                case .date:
                    TimelineView(.everyMinute) { context in
                        Group {
                            if shortDate {
                                Text(context.date, format: .dateTime.month(.abbreviated).day())
                            } else {
                                Text(context.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            }
                        }
                        .font(Theme.Role.body.bold()).foregroundStyle(Theme.dim).lineLimit(1).fixedSize()
                    }
                case .spacer: Spacer(minLength: Theme.Space.s8)
                case .seats: seatsLine
                case .exit: exitButton
                }
            }
        }
    }

    /// Weather as one mono line: "14° · 6°/19°".
    private var weatherLine: some View {
        let tile = WeatherTile(desk.payload?.weather)
        return HStack(spacing: Theme.Space.s4) {
            Image(systemName: tile.symbol).accessibilityHidden(true)
            Text(tile.temperature)
        }
        .font(.system(size: 20, weight: .bold, design: .monospaced))
        .foregroundStyle(Theme.dim)
        .lineLimit(1).fixedSize()
    }

    /// The hourly shatter (or the three-finger tap): the old frame breaks into squares and falls away while the
    /// layout, hidden under it, has already stepped to this hour's offset. Reduce Motion: a 0.4 s crossfade.
    private func runShatter(size: CGSize) {
        shatter.trigger(size: size, reduce: DeskMotion.reduce, snapshot: ShatterDirector.windowSnapshot) {
            shift = BurnIn.offset(at: Date())
        }
    }

    /// Lights-out: black, the sleeping face in the middle.
    private var sleepingFace: some View {
        HStack(spacing: Theme.Space.s12) {
            Text(Mood.asleep.face)
            Sleeper(text: Mood.asleep.suffix ?? "")
        }
        .font(.system(size: 56, weight: .bold, design: .monospaced))
        .accessibilityHidden(true)
    }

    /// "Max 62% · Team 97% · Admin 18%": mono, a seat at 90 % or more in red.
    private var seatsLine: some View {
        HStack(spacing: Theme.Space.s4) {
            ForEach(Array(SeatsLine.segments(desk.payload?.seats ?? []).enumerated()), id: \.offset) { index, seat in
                if index > 0 { Text("·").foregroundStyle(Theme.dim) }
                Text(seat.text).foregroundStyle(seat.red ? Theme.red : Theme.text)
            }
        }
        .font(.system(size: 20, weight: .bold, design: .monospaced))
        .lineLimit(1).fixedSize()
    }

    /// Room first, then what the state puts beside it. Landscape: a row; portrait: a column.
    @ViewBuilder private func tiles(_ state: DeskState, landscape: Bool, gap: CGFloat, padding: CGFloat) -> some View {
        let all = Group {
            ForEach(state.tiles, id: \.self) { tile in
                switch tile {
                case .room: roomTile(padding, compact: state.roomIsCompact)
                case .weather: weatherTile(padding)
                case .lanes: musterTile(padding)
                case .attention: attentionTile(padding)
                }
            }
        }
        if landscape {
            HStack(alignment: .top, spacing: gap) { all }
        } else {
            VStack(spacing: gap) { all }
        }
    }

    /// Bottom strip, always there: three world clocks, the next event, the rings (or today's steps).
    private enum FooterItem: Hashable { case face, clocks, spacer, next, activity }

    private func footer(_ m: DeskMetrics) -> some View {
        // Whatever does not fit goes (next event, then steps/rings), never squeezed into nonsense.
        ViewThatFits(in: .horizontal) {
            footerRow(m, [.face, .clocks, .spacer, .next, .activity])
            footerRow(m, [.face, .clocks, .spacer, .activity])
            footerRow(m, [.face, .clocks, .spacer])
        }
        .padding(.horizontal, Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: Theme.hairline))
    }

    private func footerRow(_ m: DeskMetrics, _ items: [FooterItem]) -> some View {
        HStack(spacing: m.clockGap) {
            ForEach(items, id: \.self) { item in
                switch item {
                case .face: FaceView(desk: desk)
                case .clocks: clocks(m).fixedSize()
                case .spacer: Spacer(minLength: Theme.Space.s8)
                case .next: nextEvent.fixedSize()
                case .activity: activity.fixedSize()
                }
            }
        }
    }

    private func clocks(_ m: DeskMetrics) -> some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: m.clockGap) {
                ForEach(DeskClocks.zones, id: \.label) { zone in
                    HStack(alignment: .center, spacing: Theme.Space.s4) {
                        Text(zone.label).font(Theme.Role.label).foregroundStyle(Theme.dim)
                        FlipClock(time: DeskClocks.time(context.date, zone: zone.id),
                                  font: .system(size: m.clockSize, weight: .heavy, design: .monospaced))
                    }
                }
            }
        }
    }

    @ViewBuilder private var nextEvent: some View {
        if let next = desk.nextEvent {
            TimelineView(.everyMinute) { context in
                HStack(spacing: Theme.Space.s8) {
                    Text("NEXT").font(Theme.Role.label).foregroundStyle(Theme.dim)
                    Text("\(next.title) · \(next.when(now: context.date))").font(Theme.Role.body.bold())
                }
            }
            .lineLimit(1)
        }
    }

    /// Rings once the export carries all three metrics; until then today's steps as text; else nothing.
    @ViewBuilder private var activity: some View {
        if let activity = desk.payload?.activity {
            if let rings = activity.rings {
                ActivityRings(move: rings.move, exercise: rings.exercise, stand: rings.stand)
                    .frame(width: 38, height: 38)
            } else if let steps = activity.steps {
                Text("\(steps.formatted()) steps").font(Theme.Role.data).foregroundStyle(Theme.dim).lineLimit(1)
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
                    ForEach(desk.shownLanes) { MusterLaneRow(lane: $0).transition(DeskMotion.laneTransition) }
                    if tile.hidden > 0 {
                        Text("+\(tile.hidden)").font(Theme.Role.meta.bold()).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }

    /// Header, the big number, one sub line: "45% · 舒适 · 体感 23°".
    private func roomTile(_ padding: CGFloat, compact: Bool) -> some View {
        DeskTile(label: "Room", padding: padding) { size in
            let climate = desk.roomClimate
            Spacer(minLength: 0)
            Text(climate.temperature)
                .font(.system(size: DeskMetrics.readingSize(tile: size, compact: compact), weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.4)
            Spacer(minLength: 0)
            comfortLine(climate)
        }
    }

    private func comfortLine(_ climate: ClimateTile) -> some View {
        let comfort = ComfortPolicy.assess(tempC: climate.celsius, humidity: climate.humidityPercent)
        return HStack(spacing: Theme.Space.s4) {
            Text(climate.humidity).monospacedDigit()
                .accessibilityLabel(Text("Humidity \(climate.humidity)"))
            if let word = comfort.word {
                Text("·").foregroundStyle(Theme.dim)
                Text(LocalizedStringKey(word)).foregroundStyle(Self.comfortColor(comfort))
                if let feels = ComfortPolicy.feelsLike(tempC: climate.celsius, humidity: climate.humidityPercent) {
                    Text("·").foregroundStyle(Theme.dim)
                    Text("feels \(feels)°").foregroundStyle(Theme.dim)
                }
            }
        }
        .font(Theme.Role.section.bold())
        .lineLimit(1).minimumScaleFactor(0.5)
    }

    private static func comfortColor(_ comfort: Comfort) -> Color {
        switch comfort {
        case .chilly, .dry: Color(hex: 0xffb020)
        case .warm, .humid: Color(hex: 0xff5a1f)
        case .comfortable, .unknown: Theme.dim
        }
    }

    /// Header, the big temperature, one sub line: "Clear sky · -1°/14°".
    private func weatherTile(_ padding: CGFloat) -> some View {
        let tile = WeatherTile(desk.payload?.weather)
        return DeskTile(label: "Weather", padding: padding) { size in
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                Text(tile.temperature)
                    .font(.system(size: DeskMetrics.readingSize(tile: size), weight: .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.4)
                Image(systemName: tile.symbol).font(Theme.Role.section).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s4) {
                Text(tile.summary.localizedForDisplay)
                Text("· \(tile.range.replacingOccurrences(of: " / ", with: "/"))").foregroundStyle(Theme.dim)
                if tile.stale { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
                    .accessibilityLabel(Text("stale")) }
            }
            .font(Theme.Role.section.bold())
            .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private func attentionTile(_ padding: CGFloat) -> some View {
        DeskTile(label: "Attention", padding: padding, badge: desk.attention.isEmpty ? nil : desk.attention.count,
                 flash: desk.lastArrival) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    ForEach(desk.attention) { item in
                        AttentionRow(item: item, highlighted: desk.highlighted.contains(item.id)) {
                            Task { await desk.acknowledge(item) }
                        }
                        .transition(DeskMotion.itemTransition)
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
    @State private var swatch: CGFloat = DeskMotion.reduce ? 1 : 0

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
            BoardBar(row: lane.row).animation(DeskMotion.bar, value: lane.row.fill)
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
                .scaleEffect(swatch)
                .onAppear { withAnimation(DeskMotion.laneIn) { swatch = 1 } }
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
    /// When something new arrived: the border flashes once (white → grey).
    var flash: Date?
    @State private var flashing = false
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
        .overlay(Rectangle().strokeBorder(flashing ? Theme.text : Theme.line, lineWidth: Theme.hairline))
        .onChange(of: flash) { _, new in if new != nil { pulse() } }
        .onAppear { if let flash, Date().timeIntervalSince(flash) < 2 { pulse() } }
    }

    private func pulse() {
        withTransaction(Transaction(animation: nil)) { flashing = true }
        Task { @MainActor in withAnimation(DeskMotion.borderFlash) { flashing = false } }
    }
}

/// One attention item. Warnings carry a red bar *and* a triangle (shape, not just colour);
/// a new item is drawn inverted until its highlight runs out. Tap the check to clear it.
private struct AttentionRow: View {
    let item: DeskPayload.Item
    let highlighted: Bool
    let acknowledge: () -> Void

    var body: some View {
        if let progress = item.progress {
            ProgressRow(title: item.title ?? "", progress: progress, acknowledge: progress.isFailed ? acknowledge : nil)
        } else {
            noteRow
        }
    }

    private var noteRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.s8) {
            Image(systemName: item.isWarning ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(item.isWarning ? Theme.Role.body : Theme.Role.meta)
                .foregroundStyle(item.isWarning ? Theme.red : (highlighted ? Theme.background : Theme.dim))
                .accessibilityLabel(Text(item.isWarning ? "Warning" : "Note"))
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                if let title = item.title { AttentionTitle(text: title) }
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

/// One long-running job: title left, `6,400 / 11,268 · 预计 04:10` right, a thin bar, the note in mono.
/// The bar is white, red when the job failed; only a failed row can be cleared by hand.
private struct ProgressRow: View {
    let title: String
    let progress: DeskPayload.Item.Progress
    let acknowledge: (() -> Void)?
    @State private var flash = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s8) {
                AttentionTitle(text: title)
                Spacer(minLength: 0)
                Text(progress.summary).font(Theme.Role.meta.monospacedDigit()).lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let acknowledge {
                    Button(action: acknowledge) { Image(systemName: "checkmark.square").font(Theme.Role.section) }
                        .accessibilityLabel(Text("Clear"))
                }
            }
            Rectangle().fill(Theme.line).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { box in
                        Rectangle().fill(progress.isFailed ? Theme.red : Theme.text)
                            .frame(width: box.size.width * progress.fraction)
                            .opacity(flash ? 0.15 : 1)
                            .animation(DeskMotion.bar, value: progress.fraction)
                    }
                }
            if let note = progress.note, !note.isEmpty {
                Text(note).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .padding(Theme.Space.s8)
        .accessibilityElement(children: .combine)
        .onChange(of: progress.state) { _, state in if state == "done" { blink() } }
        .onAppear { if progress.state == "done" { blink() } }
    }

    /// The bar flashes once when the job is done, before the row leaves.
    private func blink() {
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
        }
    }
}

/// Apple-style activity rings: Move, Exercise, Stand from the outside in, each a trimmed circle.
private struct ActivityRings: View {
    let move: Int
    let exercise: Int
    let stand: Int

    var body: some View {
        ZStack {
            ring(move, Color(hex: 0xfa114f), inset: 0)
            ring(exercise, Color(hex: 0x92e82a), inset: 5)
            ring(stand, Color(hex: 0x00d9f5), inset: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Move \(move)%, Exercise \(exercise)%, Stand \(stand)%"))
    }

    private func ring(_ pct: Int, _ color: Color, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: min(1, CGFloat(pct) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset + 2)
    }
}

/// The face in the bottom strip: one mono line, white on black. Its mood is `Face.mood`; this view
/// only adds the blink timer, the nod when a lane crosses a 10 % mark, and the sleeper's slow zZ.
private struct FaceView: View {
    let desk: DeskStation
    @State private var blinking = false
    @State private var nod: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let mood = Face.mood(desk.faceInput(now: context.date, blink: blinking))
            // Blinking swaps the text in place; any other change of mood crossfades.
            let base: Mood = mood == .blink ? .calm : mood
            HStack(spacing: Theme.Space.s8) {
                Text(mood.face).id(base).transition(.opacity)
                if let suffix = mood.suffix {
                    Sleeper(text: suffix).transition(.opacity)
                }
            }
            .animation(DeskMotion.face, value: base)
        }
        .font(.system(size: 26, weight: .bold, design: .monospaced))
        .lineLimit(1).fixedSize()
        .layoutPriority(2)
        .offset(y: nod)
        .accessibilityHidden(true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 4...9)))
                blinking = true
                try? await Task.sleep(for: .milliseconds(120))
                blinking = false
            }
        }
        .onChange(of: desk.nodCount) {
            guard !DeskMotion.reduce else { return }
            withAnimation(.easeOut(duration: 0.15)) { nod = 3 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeIn(duration: 0.15)) { nod = 0 }
            }
        }
    }
}

/// `zZ`, fading in and out slowly (still, under Reduce Motion).
private struct Sleeper: View {
    let text: String
    @State private var lit = false

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.dim)
            .opacity(DeskMotion.reduce || lit ? 1 : 0.15)
            .onAppear {
                guard !DeskMotion.reduce else { return }
                withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

/// Two or three fingers tapping anywhere on the desk: a recognizer on the window, so the buttons keep working.
private struct FingerTap: UIViewRepresentable {
    let touches: Int
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }

    func makeUIView(context: Context) -> UIView { Anchor(coordinator: context.coordinator, touches: touches) }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.action = action }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }

    private final class Anchor: UIView {
        let coordinator: Coordinator
        let touches: Int
        private lazy var recognizer: UITapGestureRecognizer = {
            let r = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
            r.numberOfTouchesRequired = touches
            r.cancelsTouchesInView = false
            return r
        }()

        init(coordinator: Coordinator, touches: Int) {
            self.coordinator = coordinator
            self.touches = touches
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.addGestureRecognizer(recognizer)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

/// An Attention title is never cut with an ellipsis: if it does not fit at body size it drops one step.
private struct AttentionTitle: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).font(Theme.Role.body.bold()).fixedSize()
            Text(text).font(Theme.Role.widgetBody.bold()).fixedSize()
        }
    }
}
