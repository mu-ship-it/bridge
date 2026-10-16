import Foundation
import Testing
@testable import Bridge

@Suite struct HealthIngestMapperTests {
    let tz = TimeZone(secondsFromGMT: 8 * 3600)!
    /// 2026-10-16 08:00:00 +0800
    let t0 = Date(timeIntervalSince1970: 1_792_108_800)

    private func decode(_ batch: HealthBatch) throws -> [String: Any] {
        let data = try HealthIngestMapper.encode(batch, timeZone: tz)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func dateFormatMatchesHealthAutoExport() {
        #expect(HealthIngestMapper.dateString(t0, timeZone: tz) == "2026-10-16 08:00:00 +0800")
    }

    @Test func heartRateMatchesSpecExample() throws {
        var batch = HealthBatch()
        batch.quantities[.heartRate] = [QuantityPoint(date: t0, qty: 72)]
        let data = try HealthIngestMapper.encode(batch, timeZone: tz)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"{"data":{"metrics":[{"data":[{"date":"2026-10-16 08:00:00 +0800","qty":72}],"name":"heart_rate","units":"count/min"}],"workouts":[]}}"#)
    }

    @Test func emptyMetricsAreOmittedAndOrderIsStable() throws {
        var batch = HealthBatch()
        batch.quantities[.steps] = [QuantityPoint(date: t0, qty: 120, source: "iPhone")]
        batch.quantities[.heartRate] = []
        batch.quantities[.heartRateVariability] = [QuantityPoint(date: t0, qty: 41.23456789)]
        let root = try decode(batch)
        let metrics = try #require((root["data"] as? [String: Any])?["metrics"] as? [[String: Any]])
        #expect(metrics.compactMap { $0["name"] as? String } == ["heart_rate_variability", "step_count"])
        #expect(metrics[0]["units"] as? String == "ms")
        let hrv = try #require((metrics[0]["data"] as? [[String: Any]])?.first)
        #expect(hrv["qty"] as? Double == 41.2346)
        let steps = try #require((metrics[1]["data"] as? [[String: Any]])?.first)
        #expect(steps["source"] as? String == "iPhone")
    }

    @Test func sleepBecomesSleepAnalysisMetricInHours() throws {
        var batch = HealthBatch()
        batch.sleep = [SleepSegment(start: t0, end: t0.addingTimeInterval(5400), stage: .deep)]
        let root = try decode(batch)
        let metrics = try #require((root["data"] as? [String: Any])?["metrics"] as? [[String: Any]])
        #expect(metrics.first?["name"] as? String == "sleep_analysis")
        let seg = try #require((metrics.first?["data"] as? [[String: Any]])?.first)
        #expect(seg["value"] as? String == "Deep")
        #expect(seg["qty"] as? Double == 1.5)
        #expect(seg["startDate"] as? String == "2026-10-16 08:00:00 +0800")
        #expect(seg["endDate"] as? String == "2026-10-16 09:30:00 +0800")
    }

    @Test func workoutsGoInWorkoutsArray() throws {
        var batch = HealthBatch()
        batch.workouts = [WorkoutRecord(id: "W1", name: "Running", start: t0, end: t0.addingTimeInterval(1800),
                                        activeEnergyKcal: 301.4, distanceKm: 5.02)]
        let root = try decode(batch)
        let data = try #require(root["data"] as? [String: Any])
        #expect((data["metrics"] as? [Any])?.isEmpty == true)
        let w = try #require((data["workouts"] as? [[String: Any]])?.first)
        #expect(w["name"] as? String == "Running")
        #expect(w["duration"] as? Double == 1800)
        #expect((w["activeEnergyBurned"] as? [String: Any])?["units"] as? String == "kcal")
        #expect((w["distance"] as? [String: Any])?["qty"] as? Double == 5.02)
    }

    @Test func batchSummaryAndEmptiness() {
        var batch = HealthBatch()
        #expect(batch.isEmpty)
        #expect(batch.summary == "Nothing new")
        batch.quantities[.heartRate] = [QuantityPoint(date: t0, qty: 60), QuantityPoint(date: t0, qty: 61)]
        #expect(!batch.isEmpty)
        #expect(batch.summary == "heart_rate 2")
    }

    @Test func metricAliases() {
        #expect(HealthMetric(param: "hrv") == .heartRateVariability)
        #expect(HealthMetric(param: "SpO2") == .bloodOxygen)
        #expect(HealthMetric(param: "steps") == .steps)
        #expect(HealthMetric(param: "resting_heart_rate") == .restingHeartRate)
        #expect(HealthMetric(param: "nope") == nil)
    }
}
