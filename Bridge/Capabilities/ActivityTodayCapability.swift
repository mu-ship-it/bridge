import Foundation
import HealthKit

/// Raw ring values for one day, in the units HealthKit reports them (kcal, minutes, hours). Nil = HealthKit had no value.
struct ActivitySummaryValues: Sendable, Equatable {
    var moveKcal: Double?
    var moveGoal: Double?
    var exerciseMin: Double?
    var exerciseGoal: Double?
    var standHours: Double?
    var standGoal: Double?
}

/// `activity.today` → `{date, move_kcal, move_goal, exercise_min, exercise_goal, stand_hours, stand_goal, steps: null}`
/// from HealthKit's activity summary for today (the Apple Watch rings and Mu's own goals). No params.
struct ActivityTodayCapability: Capability {
    let name = "activity.today"

    func run(_ job: Job) async throws -> JSONValue {
        let health = HealthService.shared
        guard health.isAvailable else { throw CapabilityError(code: "unavailable", message: "HealthKit not available") }
        let now = Date()
        let rings = try await health.activitySummary(on: now, calendar: .current)
        return Self.json(rings, date: now, calendar: .current)
    }

    /// Pure mapping: summary values → result JSON. Numbers are rounded; missing values are null.
    static func json(_ r: ActivitySummaryValues, date: Date, calendar: Calendar) -> JSONValue {
        func n(_ v: Double?) -> JSONValue { v.map { .number($0.rounded()) } ?? .null }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return .object([
            "date": .string(day),
            "move_kcal": n(r.moveKcal), "move_goal": n(r.moveGoal),
            "exercise_min": n(r.exerciseMin), "exercise_goal": n(r.exerciseGoal),
            "stand_hours": n(r.standHours), "stand_goal": n(r.standGoal),
            "steps": .null,
        ])
    }
}

extension HealthService {
    func activitySummary(on date: Date, calendar: Calendar) async throws -> ActivitySummaryValues {
        var c = calendar.dateComponents([.year, .month, .day], from: date)
        c.calendar = calendar
        let predicate = HKQuery.predicateForActivitySummary(with: c)
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, result, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: result ?? []) }
            }
            store.execute(q)
        }
        guard let s = summaries.first else { return ActivitySummaryValues() }
        return ActivitySummaryValues(
            moveKcal: s.activeEnergyBurned.doubleValue(for: .kilocalorie()),
            moveGoal: s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
            exerciseMin: s.appleExerciseTime.doubleValue(for: .minute()),
            exerciseGoal: s.exerciseTimeGoal?.doubleValue(for: .minute()),
            standHours: s.appleStandHours.doubleValue(for: .count()),
            standGoal: s.standHoursGoal?.doubleValue(for: .count()))
    }
}
