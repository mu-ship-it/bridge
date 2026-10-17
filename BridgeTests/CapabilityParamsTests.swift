import Foundation
import Testing
@testable import Bridge

@Suite struct CapabilityParamsTests {
    let now = Date(timeIntervalSince1970: 1_792_108_800)

    @Test func boolValueParsing() {
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.number(0).boolValue == false)
        #expect(JSONValue.string("False").boolValue == false)
        #expect(JSONValue.string("maybe").boolValue == nil)
        #expect(JSONValue.null.boolValue == nil)
    }

    @Test func clipboardSet() throws {
        #expect(try ClipboardSetParams(["text": .string("hi")]).text == "hi")
        #expect(try ClipboardSetParams(["text": .string("")]).text == "")
        #expect(throws: CapabilityError.self) { try ClipboardSetParams(nil) }
        #expect(throws: CapabilityError.self) { try ClipboardSetParams(["text": .number(3)]) }
    }

    @Test func notifyShow() throws {
        let p = try NotifyShowParams(["title": .string(" 白手套 "), "body": .string("train leaves 11:30")])
        #expect(try p == NotifyShowParams(["title": .string("白手套"), "body": .string("train leaves 11:30"), "sound": .bool(true)]))
        #expect(try NotifyShowParams(["body": .string("x"), "sound": .bool(false)]).sound == false)
        #expect(try NotifyShowParams(["title": .string("t")]).body == "")
        #expect(throws: CapabilityError.self) { try NotifyShowParams([:]) }
        #expect(throws: CapabilityError.self) { try NotifyShowParams(["title": .string("  ")]) }
        #expect(throws: CapabilityError.self) { try NotifyShowParams(["title": .string("t"), "sound": .string("loud")]) }
        #expect(throws: CapabilityError.self) { try NotifyShowParams(["title": .string(String(repeating: "x", count: 201))]) }
    }

    @Test func calendarEvents() throws {
        let d = try CalendarEventsParams(nil, now: now)
        #expect(d.from == now)
        #expect(d.to == now.addingTimeInterval(7 * 86_400))
        let r = try CalendarEventsParams(["from": .string("2026-10-16T00:00:00Z"), "to": .string("2026-10-17T00:00:00Z")], now: now)
        #expect(r.to.timeIntervalSince(r.from) == 86_400)
        #expect(throws: CapabilityError.self) { try CalendarEventsParams(["from": .string("nope")], now: now) }
        #expect(throws: CapabilityError.self) {
            try CalendarEventsParams(["from": .string("2026-10-17"), "to": .string("2026-10-16")], now: now)
        }
        #expect(throws: CapabilityError.self) {
            try CalendarEventsParams(["from": .string("2026-01-01"), "to": .string("2028-01-01")], now: now)
        }
    }

    @Test func reminders() throws {
        #expect(try RemindersListParams(nil).completed == false)
        #expect(try RemindersListParams(["completed": .bool(true)]).completed == true)
        #expect(throws: CapabilityError.self) { try RemindersListParams(["completed": .string("sometimes")]) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let a = try RemindersAddParams(["title": .string("Buy tea"), "list": .string("Errands"), "due": .string("2026-10-17T09:30:00+08:00")], calendar: cal)
        #expect(a.title == "Buy tea")
        #expect(a.list == "Errands")
        #expect(a.due?.hour == 9 && a.due?.minute == 30 && a.due?.day == 17)
        let allDay = try RemindersAddParams(["title": .string("x"), "due": .string("2026-10-20")], calendar: cal)
        #expect(allDay.due?.hour == nil)
        #expect(allDay.due?.day != nil)
        #expect(try RemindersAddParams(["title": .string("x")]).due == nil)
        #expect(throws: CapabilityError.self) { try RemindersAddParams([:]) }
        #expect(throws: CapabilityError.self) { try RemindersAddParams(["title": .string("x"), "due": .string("tomorrow")]) }
    }

    @Test func contactsSearch() throws {
        let n = try ContactsSearchParams(["query": .string("Alice")])
        #expect(n.kind == .name && n.limit == 20)
        #expect(try ContactsSearchParams(["query": .string("a@b.co")]).kind == .email)
        #expect(try ContactsSearchParams(["query": .string("+86 138-0000-0000")]).kind == .phone)
        #expect(try ContactsSearchParams(["query": .string("Bob"), "limit": .number(99)]).limit == 20)
        #expect(try ContactsSearchParams(["query": .string("Bob"), "limit": .number(0)]).limit == 1)
        #expect(throws: CapabilityError.self) { try ContactsSearchParams([:]) }
        #expect(throws: CapabilityError.self) { try ContactsSearchParams(["query": .string(" ")]) }
    }

    @Test func photosRecent() throws {
        let d = try PhotosRecentParams(nil)
        #expect(d.count == 3 && d.maxPx == 512)
        let c = try PhotosRecentParams(["count": .number(50), "max_px": .number(100_000)])
        #expect(c.count == 10 && c.maxPx == 2048)
        #expect(throws: CapabilityError.self) { try PhotosRecentParams(["count": .string("many")]) }
        #expect(PhotosRecentParams.fitted(CGSize(width: 4032, height: 3024), maxPx: 512) == CGSize(width: 512, height: 384))
        #expect(PhotosRecentParams.fitted(CGSize(width: 300, height: 200), maxPx: 512) == CGSize(width: 300, height: 200))
    }

    @Test func motionStartOfDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = MotionTodayCapability.startOfDay(now, calendar: cal)
        #expect(start <= now && now.timeIntervalSince(start) < 86_400)
        #expect(cal.dateComponents([.hour, .minute], from: start) == DateComponents(hour: 0, minute: 0))
    }

    #if targetEnvironment(simulator)
    /// Hardware-backed capabilities must return a clean error result in the simulator, never crash.
    @Test func hardwareCapabilitiesDegradeInSimulator() async {
        let dispatcher = JobDispatcher(CapabilityRegistry.all)
        let motion = await dispatcher.dispatch(Job(id: "m", capability: "motion.today"))
        #expect(!motion.ok)
        #expect(motion.error?.code == "unavailable")
        for name in ["photos.recent", "contacts.search", "calendar.events", "reminders.list"] {
            let r = await dispatcher.dispatch(Job(id: name, capability: name, params: ["query": .string("x")]))
            if !r.ok {
                #expect(["unavailable", "permission_missing", "permission_denied"].contains(r.error?.code ?? ""), "\(name): \(String(describing: r.error))")
            }
        }
    }
    #endif

    @Test func allNewCapabilitiesRegistered() {
        let names = Set(CapabilityRegistry.all.map(\.name))
        for n in ["clipboard.get", "clipboard.set", "notify.show", "calendar.events", "reminders.list",
                  "reminders.add", "contacts.search", "photos.recent", "motion.today", "agent.say"] {
            #expect(names.contains(n), "\(n) missing")
        }
    }
}

@Suite struct ActivityTests {
    @Test func agentSayParams() throws {
        let p = try AgentSayParams(["text": .string("Checked your calendar, all clear.")])
        #expect(p.text == "Checked your calendar, all clear." && p.notify == false)
        #expect(try AgentSayParams(["text": .string("hi"), "notify": .bool(true)]).notify)
        #expect(throws: CapabilityError.self) { try AgentSayParams([:]) }
        #expect(throws: CapabilityError.self) { try AgentSayParams(["text": .string(String(repeating: "x", count: 2001))]) }
        #expect(throws: CapabilityError.self) { try AgentSayParams(["text": .string("x"), "notify": .string("loud")]) }
    }

    @Test func noteDecodesFromTopLevelOrParams() throws {
        let wire = #"{"jobs":[{"id":"a","capability":"device.info","note":" Checking battery before your train "},{"id":"b","capability":"location.now","params":{"note":"Where are you?"}},{"id":"c","capability":"device.info"}]}"#
        let jobs = try JSONDecoder().decode(JobsResponse.self, from: Data(wire.utf8)).jobs
        #expect(jobs[0].displayNote == "Checking battery before your train")
        #expect(jobs[1].displayNote == "Where are you?")
        #expect(jobs[2].displayNote == nil)
    }

    @Test func summaries() {
        let say = Job(id: "s", capability: "agent.say", params: ["text": .string("On it")])
        #expect(ActivitySummary.summarize(say, JobResult(jobId: "s", ok: true, result: .object([:]), startedAt: "", finishedAt: "")) == "On it")
        let loc = Job(id: "l", capability: "location.now")
        let r = JobResult(jobId: "l", ok: true, result: .object(["lat": .number(41.80571), "lon": .number(123.4315), "horizontal_accuracy_m": .number(35)]), startedAt: "", finishedAt: "")
        #expect(ActivitySummary.summarize(loc, r) == "41.8057, 123.4315 ±35 m")
        let fail = JobResult(jobId: "l", ok: false, error: JobError(code: "permission_missing", message: "nope"), startedAt: "", finishedAt: "")
        #expect(ActivitySummary.summarize(loc, fail) == "permission_missing: nope")
        let cal = Job(id: "c", capability: "calendar.events")
        #expect(ActivitySummary.summarize(cal, JobResult(jobId: "c", ok: true, result: .object(["count": .number(4)]), startedAt: "", finishedAt: "")) == "4 item(s)")
        #expect(ActivitySummary.clip(String(repeating: "a", count: 200)).count == 120)
    }
}
