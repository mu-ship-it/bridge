import EventKit
import Foundation

/// Shared EventKit access checks. A fresh `EKEventStore` is made per job (it is not `Sendable`).
enum EventKitAccess {
    static func check(_ type: EKEntityType) throws {
        let what = type == .event ? "Calendar" : "Reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return
        case .notDetermined: throw CapabilityError.permissionMissing(what)
        case .writeOnly: throw CapabilityError(code: "permission_denied", message: "\(what) has write-only access; full access is needed. Change it in Settings.")
        default: throw CapabilityError.permissionDenied(what)
        }
    }

    static func requestCalendar() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    static func requestReminders() async -> Bool {
        (try? await EKEventStore().requestFullAccessToReminders()) ?? false
    }
}

/// Parsed `calendar.events` params: `from`, `to` (ISO-8601 or yyyy-MM-dd; default now → +7 days; max span 366 days).
struct CalendarEventsParams: Sendable, Equatable {
    let from: Date
    let to: Date

    init(_ params: [String: JSONValue]?, now: Date = Date()) throws {
        let p = params ?? [:]
        from = try Params.date(p, "from") ?? now
        to = try Params.date(p, "to") ?? from.addingTimeInterval(7 * 86_400)
        guard from < to else { throw CapabilityError.badParams("'from' must be before 'to'") }
        guard to.timeIntervalSince(from) <= 366 * 86_400 else { throw CapabilityError.badParams("Range is too long (max 366 days)") }
    }
}

/// `calendar.events` → `{from, to, count, events: [{title, start, end, location, calendar, all_day}]}` (max 500).
struct CalendarEventsCapability: Capability {
    let name = "calendar.events"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try CalendarEventsParams(job.params)
        try EventKitAccess.check(.event)
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: q.from, end: q.to, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(500)
            .map { e -> JSONValue in
                .object([
                    "title": .string(e.title ?? ""),
                    "start": .string(ISO.string(e.startDate)),
                    "end": .string(ISO.string(e.endDate)),
                    "location": e.location.map(JSONValue.string) ?? .null,
                    "calendar": .string(e.calendar?.title ?? ""),
                    "all_day": .bool(e.isAllDay),
                ])
            }
        return .object([
            "from": .string(ISO.string(q.from)),
            "to": .string(ISO.string(q.to)),
            "count": .number(Double(events.count)),
            "events": .array(Array(events)),
        ])
    }
}

/// Parsed `reminders.list` params: `completed` (default false → open reminders only).
struct RemindersListParams: Sendable, Equatable {
    let completed: Bool

    init(_ params: [String: JSONValue]?) throws {
        completed = try Params.bool(params ?? [:], "completed") ?? false
    }
}

/// `reminders.list` → `{count, reminders: [{id, title, due?, completed, list, notes?}]}` (max 500).
struct RemindersListCapability: Capability {
    let name = "reminders.list"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try RemindersListParams(job.params)
        try EventKitAccess.check(.reminder)
        let store = EKEventStore()
        let predicate = q.completed
            ? store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [JSONValue] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).prefix(500).map(RemindersMapper.json))
            }
        }
        return .object(["count": .number(Double(items.count)), "reminders": .array(items)])
    }
}

enum RemindersMapper {
    static func json(_ r: EKReminder) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(r.calendarItemIdentifier),
            "title": .string(r.title ?? ""),
            "completed": .bool(r.isCompleted),
            "list": .string(r.calendar?.title ?? ""),
        ]
        if let due = r.dueDateComponents {
            if due.hour == nil, let y = due.year, let m = due.month, let d = due.day {
                o["due"] = .string(String(format: "%04d-%02d-%02d", y, m, d))
            } else if let date = Calendar.current.date(from: due) {
                o["due"] = .string(ISO.string(date))
            }
        }
        if let notes = r.notes, !notes.isEmpty { o["notes"] = .string(notes) }
        return .object(o)
    }
}

/// Parsed `reminders.add` params: `title` (required), `due` (ISO-8601 date-time, or yyyy-MM-dd for an all-day due date), `list` (name; default list if omitted).
struct RemindersAddParams: Sendable, Equatable {
    let title: String
    let due: DateComponents?
    let list: String?

    init(_ params: [String: JSONValue]?, calendar: Calendar = .current) throws {
        let p = params ?? [:]
        guard let title = try Params.string(p, "title") else { throw CapabilityError.badParams("'title' is required") }
        self.title = title
        list = try Params.string(p, "list")
        if let raw = try Params.string(p, "due") {
            guard let date = ISO.date(raw) else { throw CapabilityError.badParams("Bad 'due' (use ISO-8601 or yyyy-MM-dd)") }
            let dateOnly = raw.count == 10
            due = calendar.dateComponents(dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: date)
        } else {
            due = nil
        }
    }
}

/// `reminders.add` {title, due?, list?} → the created reminder (same shape as `reminders.list` items).
struct RemindersAddCapability: Capability {
    let name = "reminders.add"

    func run(_ job: Job) async throws -> JSONValue {
        let p = try RemindersAddParams(job.params)
        try EventKitAccess.check(.reminder)
        let store = EKEventStore()
        let calendar: EKCalendar
        if let list = p.list {
            guard let match = store.calendars(for: .reminder).first(where: { $0.title.caseInsensitiveCompare(list) == .orderedSame }) else {
                let names = store.calendars(for: .reminder).map(\.title).joined(separator: ", ")
                throw CapabilityError(code: "not_found", message: "No reminders list named '\(list)'. Lists: \(names)")
            }
            calendar = match
        } else {
            guard let fallback = store.defaultCalendarForNewReminders() else {
                throw CapabilityError(code: "not_found", message: "No default reminders list")
            }
            calendar = fallback
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = p.title
        reminder.calendar = calendar
        reminder.dueDateComponents = p.due
        if let due = p.due, due.hour != nil, let date = Calendar.current.date(from: due) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        try store.save(reminder, commit: true)
        return RemindersMapper.json(reminder)
    }
}
