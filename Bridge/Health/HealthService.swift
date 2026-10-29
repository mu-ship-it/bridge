import Foundation
import HealthKit

struct AnchoredPage<Item: Sendable>: Sendable {
    let items: [Item]
    /// Archived HKQueryAnchor; persist only after the box accepted the batch.
    let anchor: Data
}

extension HealthMetric {
    var quantityType: HKQuantityType {
        switch self {
        case .heartRate: HKQuantityType(.heartRate)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .heartRateVariability: HKQuantityType(.heartRateVariabilitySDNN)
        case .respiratoryRate: HKQuantityType(.respiratoryRate)
        case .bloodOxygen: HKQuantityType(.oxygenSaturation)
        case .steps: HKQuantityType(.stepCount)
        }
    }

    var hkUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability: HKUnit.secondUnit(with: .milli)
        case .bloodOxygen: HKUnit.percent()
        case .steps: HKUnit.count()
        }
    }

    /// HealthKit stores SpO2 as a 0–1 fraction; HAE uses 0–100.
    var scale: Double { self == .bloodOxygen ? 100 : 1 }

    func value(of quantity: HKQuantity) -> Double { quantity.doubleValue(for: hkUnit) * scale }
}

/// Read-only HealthKit access. Never writes, never shares outside BoxClient.
final class HealthService: @unchecked Sendable {
    static let shared = HealthService()
    let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = Set(HealthMetric.allCases.map(\.quantityType))
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        types.insert(HKObjectType.activitySummaryType())
        types.insert(HKQuantityType(.activeEnergyBurned))
        types.insert(HKQuantityType(.distanceWalkingRunning))
        types.insert(HKQuantityType(.distanceCycling))
        return types
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw CapabilityError(code: "unavailable", message: "HealthKit not available on this device") }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// iOS never reveals whether *read* access was granted; we can only tell if the prompt was shown.
    func authorizationSummary() async -> String {
        guard isAvailable else { return "HealthKit unavailable" }
        do {
            switch try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes) {
            case .shouldRequest: return "Not requested yet"
            case .unnecessary: return "Prompt answered (read grants are private)"
            case .unknown: return "Unknown"
            @unknown default: return "Unknown"
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: Ad-hoc queries (health.query)

    func quantitySamples(_ metric: HealthMetric, from: Date, to: Date, limit: Int) async throws -> [QuantityPoint] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType, predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        return try await descriptor.result(for: store).map(Self.point(metric))
    }

    /// Bucketed statistics; cumulative metrics get `qty` = sum, discrete ones get Avg/Min/Max with `qty` = Avg.
    func statistics(_ metric: HealthMetric, from: Date, to: Date, interval: DateComponents) async throws -> [JSONValue] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let options: HKStatisticsOptions = metric.isCumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: metric.quantityType, predicate: predicate),
                                                               options: options,
                                                               anchorDate: Calendar.current.startOfDay(for: from),
                                                               intervalComponents: interval)
        let collection = try await descriptor.result(for: store)
        return collection.statistics().compactMap { s -> JSONValue? in
            var o: [String: JSONValue] = ["date": .string(HealthIngestMapper.dateString(s.startDate))]
            if metric.isCumulative {
                guard let sum = s.sumQuantity() else { return nil }
                o["qty"] = .number(HealthIngestMapper.round(metric.value(of: sum)))
            } else {
                guard let avg = s.averageQuantity() else { return nil }
                o["qty"] = .number(HealthIngestMapper.round(metric.value(of: avg)))
                o["Avg"] = o["qty"]
                if let mn = s.minimumQuantity() { o["Min"] = .number(HealthIngestMapper.round(metric.value(of: mn))) }
                if let mx = s.maximumQuantity() { o["Max"] = .number(HealthIngestMapper.round(metric.value(of: mx))) }
            }
            return .object(o)
        }
    }

    func sleep(from: Date, to: Date, limit: Int) async throws -> [SleepSegment] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        return try await descriptor.result(for: store).compactMap(Self.segment)
    }

    func workouts(from: Date, to: Date, limit: Int) async throws -> [WorkoutRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        return try await descriptor.result(for: store).map(Self.record)
    }

    // MARK: Anchored "what's new" queries (periodic sync)

    func newQuantities(_ metric: HealthMetric, anchor: Data?, fallbackStart: Date, limit: Int) async throws -> AnchoredPage<QuantityPoint> {
        let a = Self.unarchive(anchor)
        let predicate = a == nil ? HKQuery.predicateForSamples(withStart: fallbackStart, end: nil) : nil
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType, predicate: predicate)],
                                                         anchor: a, limit: limit)
        let result = try await descriptor.result(for: store)
        return AnchoredPage(items: result.addedSamples.map(Self.point(metric)), anchor: try Self.archive(result.newAnchor))
    }

    func newSleep(anchor: Data?, fallbackStart: Date, limit: Int) async throws -> AnchoredPage<SleepSegment> {
        let a = Self.unarchive(anchor)
        let predicate = a == nil ? HKQuery.predicateForSamples(withStart: fallbackStart, end: nil) : nil
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                         anchor: a, limit: limit)
        let result = try await descriptor.result(for: store)
        return AnchoredPage(items: result.addedSamples.compactMap(Self.segment), anchor: try Self.archive(result.newAnchor))
    }

    func newWorkouts(anchor: Data?, fallbackStart: Date, limit: Int) async throws -> AnchoredPage<WorkoutRecord> {
        let a = Self.unarchive(anchor)
        let predicate = a == nil ? HKQuery.predicateForSamples(withStart: fallbackStart, end: nil) : nil
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout(predicate)], anchor: a, limit: limit)
        let result = try await descriptor.result(for: store)
        return AnchoredPage(items: result.addedSamples.map(Self.record), anchor: try Self.archive(result.newAnchor))
    }

    // MARK: Conversion

    private static func point(_ metric: HealthMetric) -> (HKQuantitySample) -> QuantityPoint {
        { s in QuantityPoint(date: s.startDate, qty: metric.value(of: s.quantity), source: s.sourceRevision.source.name) }
    }

    private static func segment(_ s: HKCategorySample) -> SleepSegment? {
        let stage: SleepStage
        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        case .asleepUnspecified: stage = .asleep
        default: return nil
        }
        return SleepSegment(start: s.startDate, end: s.endDate, stage: stage, source: s.sourceRevision.source.name)
    }

    private static func record(_ w: HKWorkout) -> WorkoutRecord {
        let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let distance = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
            .lazy.compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) }.first
        return WorkoutRecord(id: w.uuid.uuidString, name: w.workoutActivityType.displayName,
                             start: w.startDate, end: w.endDate,
                             activeEnergyKcal: energy, distanceKm: distance, source: w.sourceRevision.source.name)
    }

    private static func archive(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .yoga: "Yoga"
        case .functionalStrengthTraining: "Functional Strength Training"
        case .traditionalStrengthTraining: "Traditional Strength Training"
        case .highIntensityIntervalTraining: "HIIT"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair Climbing"
        case .coreTraining: "Core Training"
        case .pilates: "Pilates"
        case .dance: "Dance"
        case .tennis: "Tennis"
        case .badminton: "Badminton"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .mixedCardio: "Mixed Cardio"
        case .cooldown: "Cooldown"
        default: "Workout \(rawValue)"
        }
    }
}
