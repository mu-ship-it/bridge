import Foundation
import Testing
@testable import Bridge

@Suite struct WidgetSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func encodeDecodeRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            rows: [.init(id: "j_1", capability: "speak", note: "Say hi", status: .done,
                         startedAt: t0, finishedAt: t0.addingTimeInterval(3), summary: "said: hi")],
            agentLine: "Hello", lastPoll: t0, lastHealth: "Synced 4 metrics", generatedAt: t0)
        let decoded = try WidgetSnapshot.decode(try snapshot.encoded())
        #expect(decoded == snapshot)
        #expect(String(decoding: try snapshot.encoded(), as: UTF8.self).contains("\"generatedAt\":\"2027-01-15T08:00:00Z\""))
    }

    @Test func keepsOnlyTheNewestFiveRows() {
        let rows = (0..<8).map { WidgetSnapshot.Row(id: "j_\($0)", capability: "torch", note: nil, status: .done, summary: "") }
        #expect(WidgetSnapshot(rows: rows, agentLine: nil, lastPoll: nil, lastHealth: nil).rows.map(\.id)
                == ["j_0", "j_1", "j_2", "j_3", "j_4"])
    }

    @Test func decodesTheBoxFeedAndKeepsLocalFields() throws {
        let json = """
        {"jobs": [{"id": "j_2", "capability": "device.info", "note": null, "status": "done",
                   "finished_at": "2027-01-15T08:00:02Z", "summary": "battery 85% charging"},
                  {"id": "j_1", "capability": "location.now", "note": "Home?", "status": "running",
                   "finished_at": null, "summary": ""}],
         "agent_line": "Morning", "server_time": "2027-01-15T08:01:00Z"}
        """
        let feed = try JSONDecoder().decode(WidgetSnapshot.Feed.self, from: Data(json.utf8))
        let local = WidgetSnapshot(rows: [.init(id: "j_1", capability: "location.now", note: "Home?", status: .running,
                                                startedAt: t0, summary: "")],
                                   agentLine: nil, lastPoll: t0, lastHealth: "Synced", generatedAt: t0)
        let snapshot = WidgetSnapshot(feed: feed, local: local, now: t0)
        #expect(snapshot.source == "box" && snapshot.agentLine == "Morning" && snapshot.headline == "Morning")
        #expect(snapshot.lastPoll == t0 && snapshot.lastHealth == "Synced")
        #expect(snapshot.rows[0].finishedAt == t0.addingTimeInterval(2))
        #expect(snapshot.rows[0].title == "battery 85% charging")
        #expect(snapshot.rows[1].status == .running && snapshot.rows[1].startedAt == t0)
    }

    @Test func dotColoursAndStaleness() {
        let s = WidgetSnapshot(rows: [], agentLine: nil, lastPoll: nil, lastHealth: nil, generatedAt: t0)
        func row(_ status: WidgetSnapshot.Row.Status) -> WidgetSnapshot.Row {
            .init(id: "j", capability: "torch", note: nil, status: status, startedAt: t0, summary: "")
        }
        let soon = t0.addingTimeInterval(60)
        #expect(s.dot(for: row(.running), now: soon) == .running)
        #expect(s.dot(for: row(.queued), now: soon) == .running)
        #expect(s.dot(for: row(.done), now: soon) == .done)
        #expect(s.dot(for: row(.failed), now: soon) == .failed)
        #expect(s.dot(for: row(.done), now: t0.addingTimeInterval(3601)) == .stale)
    }

    @Test func snapshotFromTheActivityFeed() {
        let feed = [
            ActivityEntry(id: "3", time: t0, capability: "device.info", note: "Battery", status: .running, summary: ""),
            ActivityEntry(id: "2", time: t0, capability: "agent.say", note: nil, status: .done, summary: "Newest line"),
            ActivityEntry(id: "1", time: t0, capability: "agent.say", note: nil, status: .done, summary: "Older line"),
        ]
        #expect(WidgetPublisher.agentLine(feed) == "Newest line")
        let rows = WidgetPublisher.rows(feed)
        #expect(rows.map(\.id) == ["3", "2", "1"] && rows[0].status == .running && rows[0].startedAt == t0)
        #expect(WidgetPublisher.agentLine([]) == nil)
    }
}
