import Foundation
import EventKit
import Observation
import SwiftUI
import UIKit

/// The desk display (值班台): a phone parked on a desk, plugged in, 白手套 on screen all day.
/// While the Desk screen is up it fetches the box's desk payload every 30 s and reads the room
/// sensor through HomeKit every 60 s. Jobs keep running through the app's one foreground poll
/// (ForegroundSession); showing the desk counts as duty, so the screen stays awake.
@MainActor @Observable
final class DeskStation {
    static let shared = DeskStation()
    nonisolated static let payloadInterval: Duration = .seconds(30)
    nonisolated static let climateInterval: Duration = .seconds(60)
    /// How long a new item stays highlighted.
    nonisolated static let highlightSeconds: TimeInterval = 8
    private static let startInDeskKey = "desk.startInDesk"
    private static let sensorKey = "desk.sensor"

    /// Settings: a relaunch lands straight on the desk.
    var startInDesk: Bool {
        didSet { UserDefaults.standard.set(startInDesk, forKey: Self.startInDeskKey) }
    }
    /// Settings: the room sensor, by accessory or room name; empty = the first that has one.
    var sensorName: String {
        didSet { UserDefaults.standard.set(sensorName, forKey: Self.sensorKey) }
    }
    /// The Desk screen is up (instead of the tabs).
    var showing: Bool {
        didSet {
            DutyStation.shared.deskShowing = showing
            if showing != oldValue { Self.updateOrientations(desk: showing) }
        }
    }

    private(set) var payload: DeskPayload?
    private(set) var fetchedAt: Date?
    private(set) var payloadError: String?
    private(set) var climate = ClimateTile(celsius: nil, humidity: nil, sensor: nil)
    private(set) var climateError: String?
    /// The muster lanes, from the Board widget's own fetch (GET /bridge/board/muster).
    private(set) var muster = MusterTile(nil)
    /// Lanes that just left the board, kept for a moment at 100 % before their rows collapse.
    private(set) var departing: [MusterTile.Lane] = []
    /// Bumped whenever a lane's bar crosses a 10 % mark: the face nods.
    private(set) var nodCount = 0
    private(set) var awayTracker = AwayTracker()
    /// When a two-finger tap started the lights-out by hand.
    private(set) var lightsOutSince: Date?
    @ObservationIgnored private var laneMarks: [String: Int] = [:]
    /// The next timed event within 24 h on the phone's own calendars; nil without access or events.
    private(set) var nextEvent: NextEvent?
    /// Ids of items that arrived since the screen came up, until their highlight runs out.
    private(set) var highlighted: Set<String> = []
    /// When the newest item arrived (phase 3: forces the screen bright for a while).
    private(set) var lastArrival: Date?
    @ObservationIgnored private var seen: Set<String>?
    /// The front camera's view of Mu (CamPresence); `unknown` while it is off.
    private(set) var cam = CamDetector()
    /// Critical heat stopped the camera: the Attention list says so (never silent).
    private(set) var camPausedForHeat = false
    @ObservationIgnored private let camera = DeskCamera()
    @ObservationIgnored private var cameraRunning = false
    /// The last camera state sent to the box, and when (CamReport).
    @ObservationIgnored private var lastReport: (state: CamState, at: Date)?

    private init() {
        let defaults = UserDefaults.standard
        startInDesk = defaults.bool(forKey: Self.startInDeskKey)
        sensorName = defaults.string(forKey: Self.sensorKey) ?? ""
        showing = defaults.bool(forKey: Self.startInDeskKey)
        DutyStation.shared.deskShowing = showing
    }

    /// What the Room tile shows: the box's sensor reading, else HomeKit's.
    var roomClimate: ClimateTile { ClimateSourcePolicy.choose(server: payload?.room, homeKit: climate) }

    var attention: [DeskPayload.Item] { (camPausedForHeat ? [CamHeat.item] : []) + (payload?.attention ?? []) }

    /// What the Lanes tile draws: the board's lanes, then any that just finished.
    var shownLanes: [MusterTile.Lane] { muster.lanes + departing }

    /// Two-finger tap: lights-out for 60 s; tapping again during it brings the layout back.
    func toggleLightsOut(now: Date = Date()) {
        lightsOutSince = BurnIn.lightsOut(at: now, manualSince: lightsOutSince) ? nil : now
    }

    /// The camera's own opinion when it has one, else the box's presence.
    func isPresent(now: Date = Date()) -> Bool {
        BrightnessPolicy.isPresent(camera: cam.state(now: now), payload?.presence, fetchedAt: fetchedAt, now: now)
    }

    /// Away long enough that the desk goes black (BrightnessPolicy.isLightsOut).
    func isLightsOut(now: Date = Date()) -> Bool {
        BrightnessPolicy.isLightsOut(camera: cam.state(now: now), payload?.presence, fetchedAt: fetchedAt, now: now)
    }

    /// Called once a second by the desk screen.
    func trackPresence(now: Date = Date()) { awayTracker.update(present: isPresent(now: now), now: now) }

    func faceInput(now: Date, blink: Bool = false) -> FaceInput {
        var input = Face.input(attention: attention, seats: payload?.seats ?? [], lanes: muster.lanes.count)
        input.awayFor = awayTracker.awayFor(now: now)
        input.glance = NightGlance.isActive(now: now, present: isPresent(now: now))
        input.looking = cam.state(now: now) == .looking
        input.blink = blink
        return input
    }

    /// The screen level the desk wants right now (BrightnessPolicy).
    func brightness(now: Date = Date()) -> CGFloat {
        let state = cam.state(now: now)
        return BrightnessPolicy.level(present: isPresent(now: now), lastArrival: lastArrival, now: now,
                                      looking: state.isPresent ? state == .looking : nil,
                                      light: state == .unknown ? nil : cam.light, lightsOut: isLightsOut(now: now))
    }

    /// The desk may turn sideways; the tabs may not (AppDelegate). Leaving the desk on its side
    /// turns the window back to portrait.
    private static func updateOrientations(desk: Bool) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !desk, UIDevice.current.userInterfaceIdiom == .phone {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    // MARK: Loops (run from the Desk screen's .task: they stop when it goes away)

    func runPayload() async {
        seen = nil   // a fresh screen announces nothing that was already there
        while !Task.isCancelled {
            await refreshPayload()
            await refreshMuster()
            refreshNextEvent()
            try? await Task.sleep(for: Self.payloadInterval)
        }
    }

    func runClimate() async {
        while !Task.isCancelled {
            await refreshClimate()
            try? await Task.sleep(for: Self.climateInterval)
        }
    }

    /// The front camera (CamPresence): on only while the desk is up on duty (the app in front) and
    /// the phone is not critically hot; while the room sensor reads nobody it only takes a probe
    /// frame a minute (CamGate). Frames stay in DeskCamera.
    func runCamera() async {
        while !Task.isCancelled {
            let now = Date()
            let thermal = ProcessInfo.processInfo.thermalState
            camPausedForHeat = thermal == .critical
            let gateOpen = CamGate.open(payload?.presence?.roomSensor, fetchedAt: fetchedAt, now: now)
            let want = DutyStation.shared.isOnDuty && cam.wantsCamera(thermal: thermal)
            if want, !cameraRunning {
                if await DeskCamera.authorize() { cameraRunning = await camera.start() }
                if !cameraRunning { cam.interrupted(now: Date()) }
            } else if !want, cameraRunning {
                await stopCamera()
            }
            if cameraRunning {
                let probe = cam.probing(gateOpen: gateOpen)
                if let frame = await camera.frame(orientation: DeskCamera.orientation, timeout: CamPresence.frameTimeout) {
                    cam.observe(frame, now: Date(), probe: probe)
                } else {
                    await stopCamera()   // interrupted: the next pass tries again
                }
            }
            reportCamera()
            try? await Task.sleep(for: .seconds(cam.interval(now: Date(), thermal: thermal, cameraOn: cameraRunning, gateOpen: gateOpen)))
        }
        await stopCamera()
    }

    /// Camera off now (the desk left the screen, the app went to the background): no opinion until it is back.
    func stopCamera() async {
        cameraRunning = false
        await camera.stop()
        if cam.phase != .unknown { cam.interrupted(now: Date()) }
        reportCamera()
    }

    /// Tells the box the camera's state when it changed or is due again; outside the caller's
    /// cancellation, so the last `unknown` still goes out as the app leaves the screen.
    private func reportCamera(now: Date = Date()) {
        let state = cam.state(now: now)
        guard CamReport.due(state, last: lastReport, now: now), let config = ConfigStore.load() else { return }
        lastReport = (state, now)
        let report = CamReport(device: config.deviceId, state: state, light: state == .unknown ? nil : cam.light, now: now)
        Task {
            do {
                try await BackgroundTime.run("desk camera state") { try await BoxClient(config: config).postCamera(report) }
            } catch {
                self.lastReport = nil   // try again on the next pass
            }
        }
    }

    func refreshPayload(now: Date = Date()) async {
        guard let config = ConfigStore.load() else {
            payloadError = BoxError.notConfigured.localizedDescription
            return
        }
        do {
            let fresh = try await BoxClient(config: config).fetchDesk()
            accept(fresh, now: now)
            payloadError = nil
        } catch is CancellationError {
        } catch {
            payloadError = error.localizedDescription
        }
    }

    func accept(_ fresh: DeskPayload, now: Date = Date()) {
        let arrived = AttentionDiff.newItems(fresh.attention, seen: seen)
        seen = Set(fresh.attention.map(\.id))
        let removed = !Set(attention.map(\.id)).subtracting(fresh.attention.map(\.id)).isEmpty
        withAnimation(!arrived.isEmpty ? DeskMotion.itemIn : (removed ? DeskMotion.itemOut : nil)) {
            payload = fresh
        }
        fetchedAt = now
        guard !arrived.isEmpty else { return }
        announce(arrived, now: now)
    }

    /// The board the Board widget fetches and keeps; its saved copy when the box is unreachable.
    /// Never saved from here: what the widget last drew stays the widget's business.
    func refreshMuster() async {
        let snapshot = await SharedStore.fetchBoard(MusterTile.boardName) ?? SharedStore.loadBoard(MusterTile.boardName)
        let fresh = MusterTile(snapshot?.board)
        let finished = LaneDeparture.finished(old: muster.lanes, new: fresh.lanes)
        let wait = finished.map { gone in
            LaneDeparture.wait(previous: muster.lanes.first { $0.id == gone.id })
        }.max() ?? .zero
        let crossings = ProgressMarks.crossings(old: laneMarks, lanes: fresh.lanes.map { ($0.id, $0.row.fill) })
        laneMarks = crossings.marks
        if crossings.crossed { nodCount += 1 }
        let appeared = !Set(fresh.lanes.map(\.id)).subtracting(muster.lanes.map(\.id)).isEmpty
        withAnimation(appeared ? DeskMotion.laneIn : DeskMotion.bar) {
            muster = fresh
            departing.removeAll { gone in fresh.lanes.contains { $0.id == gone.id } }
            departing += finished
        }
        if !finished.isEmpty { holdThenCollapse(finished, wait: wait) }
    }

    /// Each finished lane shows full (the bar's own animation first), holds, then its row collapses.
    private func holdThenCollapse(_ lanes: [MusterTile.Lane], wait: Duration) {
        let ids = Set(lanes.map(\.id))
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            withAnimation(DeskMotion.laneOut) { self?.departing.removeAll { ids.contains($0.id) } }
        }
    }

    /// The `calendar.events` capability's source (EventKit), read only when Calendar is already allowed.
    func refreshNextEvent(now: Date = Date()) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { nextEvent = nil; return }
        let store = EKEventStore()
        let found = store.events(matching: store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(NextEvent.window), calendars: nil))
        nextEvent = NextEvent.pick(found.map { ($0.title ?? "", $0.startDate, $0.isAllDay) }, now: now)
    }

    func refreshClimate() async {
        do {
            let reading = try await HomeStore.shared.climate(wanted: sensorName)
            climate = ClimateTile(celsius: reading.celsius, humidity: reading.humidity, sensor: reading.sensor)
            climateError = nil
        } catch is CancellationError {
        } catch {
            climate = ClimateTile(celsius: nil, humidity: nil, sensor: nil)
            climateError = error.localizedDescription
        }
    }

    // MARK: New items

    private func announce(_ items: [DeskPayload.Item], now: Date) {
        lastArrival = now
        let ids = Set(items.map(\.id))
        highlighted.formUnion(ids)
        UINotificationFeedbackGenerator().notificationOccurred(items.contains(where: \.isWarning) ? .warning : .success)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.highlightSeconds))
            self?.highlighted.subtract(ids)
        }
        // Never audio, unless the item asks for it.
        let spoken = items.filter(\.speak).map { [$0.title, $0.text].compactMap { $0 }.joined(separator: ". ") }
        if !spoken.isEmpty {
            Task {
                for text in spoken {
                    guard let params = try? SpeakParams(["text": .string(text)]) else { continue }
                    _ = try? await Speaker.shared.speak(params.text, rate: params.rate, voice: try? params.resolvedVoice())
                }
            }
        }
    }

    // MARK: Ack

    /// Mu cleared an item: drop it here at once and tell the box (it leaves the list there too).
    func acknowledge(_ item: DeskPayload.Item) async {
        guard !CamHeat.isLocal(item) else { return }
        if let current = payload {
            withAnimation(DeskMotion.itemOut) {
                payload = DeskPayload(time: current.time, weather: current.weather, room: current.room,
                                      attention: current.attention.filter { $0.id != item.id },
                                      presence: current.presence, seats: current.seats, activity: current.activity)
            }
        }
        highlighted.remove(item.id)
        guard let config = ConfigStore.load() else { return }
        do {
            try await BoxClient(config: config).postEvents([DeskAck.event(ids: [item.id])])
        } catch {
            payloadError = error.localizedDescription
        }
    }
}
