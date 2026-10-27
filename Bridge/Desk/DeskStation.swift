import Foundation
import Observation
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
        didSet { DutyStation.shared.deskShowing = showing }
    }

    private(set) var payload: DeskPayload?
    private(set) var fetchedAt: Date?
    private(set) var payloadError: String?
    private(set) var climate = ClimateTile(celsius: nil, humidity: nil, sensor: nil)
    private(set) var climateError: String?
    /// Ids of items that arrived since the screen came up, until their highlight runs out.
    private(set) var highlighted: Set<String> = []
    /// When the newest item arrived (phase 3: forces the screen bright for a while).
    private(set) var lastArrival: Date?
    @ObservationIgnored private var seen: Set<String>?

    private init() {
        let defaults = UserDefaults.standard
        startInDesk = defaults.bool(forKey: Self.startInDeskKey)
        sensorName = defaults.string(forKey: Self.sensorKey) ?? ""
        showing = defaults.bool(forKey: Self.startInDeskKey)
        DutyStation.shared.deskShowing = showing
    }

    var attention: [DeskPayload.Item] { payload?.attention ?? [] }

    // MARK: Loops (run from the Desk screen's .task: they stop when it goes away)

    func runPayload() async {
        seen = nil   // a fresh screen announces nothing that was already there
        while !Task.isCancelled {
            await refreshPayload()
            try? await Task.sleep(for: Self.payloadInterval)
        }
    }

    func runClimate() async {
        while !Task.isCancelled {
            await refreshClimate()
            try? await Task.sleep(for: Self.climateInterval)
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
        payload = fresh
        fetchedAt = now
        guard !arrived.isEmpty else { return }
        announce(arrived, now: now)
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
        if let current = payload {
            payload = DeskPayload(time: current.time, weather: current.weather,
                                  attention: current.attention.filter { $0.id != item.id }, presence: current.presence)
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
