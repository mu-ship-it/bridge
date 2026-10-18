import Foundation
import Testing
import UIKit
@testable import Bridge

@Suite struct DutyModeTests {
    @Test func uptimeReadsWellFromSecondsToDays() {
        #expect(DutyStation.uptimeText(-3) == "0s")
        #expect(DutyStation.uptimeText(45) == "45s")
        #expect(DutyStation.uptimeText(12 * 60 + 59) == "12m")
        #expect(DutyStation.uptimeText(3 * 3600 + 4 * 60) == "3h 04m")
        #expect(DutyStation.uptimeText(2 * 86_400 + 3 * 3600 + 59 * 60) == "2d 3h")
    }

    @Test func heartbeatIsDeviceInfoShapedPlusDutyFields() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let now = since.addingTimeInterval(3_725)
        let lastJob = since.addingTimeInterval(60)
        let event = DutyStation.heartbeatEvent(base: ["battery_level": .number(1), "model": .string("iPad")],
                                               reason: .interval, since: since, connection: .live,
                                               lastJob: lastJob, windows: 2, now: now)
        #expect(event.type == "heartbeat")
        #expect(event.ts == ISO.string(now))
        #expect(!event.note.isEmpty)
        let p = try #require(event.payload)
        #expect(p["battery_level"] == .number(1) && p["model"] == .string("iPad"))
        #expect(p["duty"] == .bool(true))
        #expect(p["reason"] == .string("interval"))
        #expect(p["uptime_s"] == .number(3_725))
        #expect(p["on_duty_since"] == .string(ISO.string(since)))
        #expect(p["last_job_at"] == .string(ISO.string(lastJob)))
        #expect(p["foreground_windows"] == .number(2))
        #expect(p["heartbeat_interval_s"] == .number(300))
    }

    @Test func theGoodbyeBeatSaysOffDutyAndWhy() throws {
        let event = DutyStation.heartbeatEvent(base: [:], reason: .stop("白手套 left the screen"), since: nil,
                                               connection: .idle, lastJob: nil, windows: 0, now: Date())
        #expect(event.note == "Off duty: 白手套 left the screen")
        let p = try #require(event.payload)
        #expect(p["duty"] == .bool(false))
        #expect(p["uptime_s"] == .null && p["last_job_at"] == .null)
    }

    @Test func connectionStateFollowsEachRound() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ConnectionState.after(.ran(jobs: 0), pause: 0, failures: 0, now: now) == .live)
        #expect(ConnectionState.after(.failed, pause: 8, failures: 3, now: now) == .retrying(at: now.addingTimeInterval(8), failures: 3))
        #expect(ConnectionState.after(.notConfigured, pause: 2, failures: 1, now: now) == .notConfigured)
        #expect(ConnectionState.after(.busy, pause: 1, failures: 0, now: now) == nil)
        #expect(ConnectionState.after(.cancelled, pause: 0, failures: 0, now: now) == nil)
        #expect(ConnectionState.live.isHealthy && !ConnectionState.connecting.isHealthy)
    }

    @Test func onlyANarrowIPadWindowCollapsesToTheFeed() {
        #expect(StatusLayout.isCompact(width: 400, idiom: .pad))
        #expect(!StatusLayout.isCompact(width: 1024, idiom: .pad))
        #expect(!StatusLayout.isCompact(width: 0, idiom: .pad))      // not measured yet
        #expect(!StatusLayout.isCompact(width: 393, idiom: .phone))  // an iPhone keeps everything
    }

    @Test func eventsArePostedForThisDeviceWithTheBearerToken() throws {
        let client = BoxClient(config: BridgeConfig(baseURL: URL(string: "https://box.example")!, token: "t", deviceId: "my-ipad"))
        let event = DeviceEvent(type: "heartbeat", ts: "2026-10-17T09:00:00Z", payload: .object(["duty": .bool(true)]), note: "n")
        let request = try client.eventsRequest([event])
        #expect(request.url?.absoluteString == "https://box.example/bridge/events")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["device"] == .string("my-ipad"))
        #expect(body["events"]?.arrayValue?.first?["payload"]?["duty"] == .bool(true))
        #expect(body["events"]?.arrayValue?.first?["note"] == .string("n"))
    }

    @MainActor @Test func theAppIsAResizableMultiWindowIPadApp() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let manifest = try #require(info["UIApplicationSceneManifest"] as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect(info["UIRequiresFullScreen"] as? Bool == false)
        // Bundle folds `~ipad` keys into the base key on an iPad, so check what this device gets.
        let orientations = try #require(info["UISupportedInterfaceOrientations"] as? [String])
        #expect(Set(orientations).count == (UIDevice.current.userInterfaceIdiom == .pad ? 4 : 1))
        let families = try #require(info["UIDeviceFamily"] as? [Int])
        #expect(families.contains(1) && families.contains(2))
    }
}
