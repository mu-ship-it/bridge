import AVFoundation
import Foundation
import Testing
@testable import Bridge

@Suite struct VoiceChoiceTests {
    private func v(_ id: String, _ lang: String, _ q: VoiceCandidate.Quality, special: Bool = false) -> VoiceCandidate {
        VoiceCandidate(identifier: id, name: id, language: lang, quality: q, special: special)
    }

    @Test func premiumBeatsEnhancedBeatsCompact() {
        let voices = [v("tingting", "zh-CN", .compact), v("lili", "zh-CN", .premium), v("yu", "zh-CN", .enhanced)]
        #expect(VoiceCandidate.best(for: "zh-CN", among: voices)?.identifier == "lili")
        #expect(VoiceCandidate.best(for: "zh-CN", among: Array(voices.prefix(1)) + [voices[2]])?.identifier == "yu")
    }

    @Test func exactRegionWinsAtEqualQualityAndBaseLanguageMatchesAnyRegion() {
        let voices = [v("au", "en-AU", .enhanced), v("us", "en-US", .enhanced), v("gb", "en-GB", .premium)]
        #expect(VoiceCandidate.best(for: "en-US", among: voices)?.identifier == "gb")     // quality first
        #expect(VoiceCandidate.best(for: "en-US", among: Array(voices.prefix(2)))?.identifier == "us")
        #expect(VoiceCandidate.best(for: "en", among: voices)?.identifier == "gb")
        #expect(VoiceCandidate.best(for: "fr-FR", among: voices) == nil)
    }

    @Test func noveltyAndPersonalVoicesAreSkipped() {
        let voices = [v("bells", "en-US", .premium, special: true), v("samantha", "en-US", .compact)]
        #expect(VoiceCandidate.best(for: "en-US", among: voices)?.identifier == "samantha")
    }

    @Test func explicitIdentifierStillWins() throws {
        guard let any = AVSpeechSynthesisVoice.speechVoices().first?.identifier else { return }   // no voices installed
        #expect(try SpeakParams(["text": .string("hi"), "voice": .string(any)]).resolvedVoice()?.identifier == any)
    }
}

@Suite struct FilesExportTests {
    private let now = ISO.date("2026-10-19T08:00:00Z")!

    @Test func paramsValidateEveryMetricBeforeRunning() throws {
        let p = try FilesExportParams(["metrics": .array([.string("heart_rate"), .string("step_count"), .string("heart_rate")]),
                                       "from": .string("2026-10-12T00:00:00Z"), "to": .string("2026-10-19T00:00:00Z")], now: now)
        #expect(p.metrics == ["heart_rate", "step_count"])
        #expect(p.name == "health-2026-10-12_2026-10-19.json")
        #expect(p.query("heart_rate")["interval"] == .string("raw"))
        #expect(try FilesExportParams(["metrics": .array([.string("sleep")])], now: now).from == now.addingTimeInterval(-86400))
        #expect(throws: CapabilityError.self) { try FilesExportParams([:]) }
        #expect(throws: CapabilityError.self) { try FilesExportParams(["metrics": .array([])]) }
        #expect(throws: CapabilityError.self) { try FilesExportParams(["metrics": .array([.string("nope")])]) }
        #expect(throws: CapabilityError.self) { try FilesExportParams(["metrics": .array([.number(1)])]) }
        #expect(throws: CapabilityError.self) {
            try FilesExportParams(["metrics": .array([.string("sleep")]), "name": .string("../x.json")])
        }
    }

    @Test func writesOneJSONFileAndRecordsFailedMetrics() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let capability = FilesExportCapability(store: FileStore(root: root)) { job in
            if job.params?["metric"] == .string("step_count") { throw CapabilityError.permissionDenied("Health") }
            return .object(["count": .number(2), "metric": .object(["name": job.params!["metric"]!])])
        }
        let result = await JobDispatcher([capability]).dispatch(Job(id: "x", capability: "files.export", params: [
            "metrics": .array([.string("heart_rate"), .string("step_count")]), "name": .string("hr.json")]))
        #expect(result.ok)
        #expect(result.result?["path"] == .string("On My iPhone/白手套/hr.json"))
        #expect(result.result?["metrics"] == .number(1) && result.result?["failed"] == .array([.string("step_count")]))
        let data = try Data(contentsOf: root.appending(path: "hr.json"))
        #expect(result.result?["bytes"] == .number(Double(data.count)))
        let file = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(file["results"]?["heart_rate"]?["count"] == .number(2))
        #expect(file["results"]?["step_count"]?["error"]?["code"] == .string("permission_denied"))
    }

    @Test func failsWhenEveryMetricFails() async {
        let capability = FilesExportCapability(store: FileStore(root: FileManager.default.temporaryDirectory)) { _ in
            throw CapabilityError(code: "unavailable", message: "HealthKit not available")
        }
        let result = await JobDispatcher([capability]).dispatch(Job(id: "y", capability: "files.export",
                                                                    params: ["metrics": .array([.string("sleep")])]))
        #expect(!result.ok && result.error?.code == "unavailable")
    }
}

@Suite struct VersionTests {
    @Test func marketingVersionAndCommitCountBuildNumber() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.5")
        let build = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect((Int(build) ?? 0) > 5, "build number should be the git commit count, got \(build)")
    }
}
