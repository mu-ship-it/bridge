import Foundation
import Testing
@testable import Bridge

private struct StubCapability: Capability {
    let name: String
    var reply: JSONValue = .object(["pong": .bool(true)])

    func run(_ job: Job) async throws -> JSONValue {
        if job.params?["fail"] != nil { throw CapabilityError(code: "stub_failed", message: "asked to fail") }
        if job.params?["crash"] != nil { throw URLError(.timedOut) }
        return .object(["echo": job.params.map(JSONValue.object) ?? .null, "reply": reply])
    }
}

@Suite struct JobDispatcherTests {
    let fixed: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_792_108_800) }
    let dispatcher = JobDispatcher([StubCapability(name: "stub.echo"), StubCapability(name: "stub.echo", reply: .string("dup"))])

    @Test func routesByCapabilityName() async {
        let job = Job(id: "j1", capability: "stub.echo", params: ["x": .number(1)])
        let r = await dispatcher.dispatch(job, now: fixed)
        #expect(r.ok)
        #expect(r.jobId == "j1")
        #expect(r.error == nil)
        #expect(r.result?["echo"]?["x"] == .number(1))
        // Duplicate names: first registration wins.
        #expect(r.result?["reply"]?["pong"] == .bool(true))
        #expect(r.startedAt == ISO.string(fixed()))
    }

    @Test func unknownCapabilityIsAnErrorResult() async {
        let r = await dispatcher.dispatch(Job(id: "j2", capability: "nope"), now: fixed)
        #expect(!r.ok)
        #expect(r.error?.code == "unknown_capability")
        #expect(r.result == nil)
    }

    @Test func capabilityErrorKeepsItsCode() async {
        let r = await dispatcher.dispatch(Job(id: "j3", capability: "stub.echo", params: ["fail": .bool(true)]))
        #expect(!r.ok)
        #expect(r.error == JobError(code: "stub_failed", message: "asked to fail"))
    }

    @Test func otherErrorsBecomeFailed() async {
        let r = await dispatcher.dispatch(Job(id: "j4", capability: "stub.echo", params: ["crash": .bool(true)]))
        #expect(r.error?.code == "failed")
    }

    @Test func jobsAndResultsRoundTripContractJSON() throws {
        let wire = #"{"jobs":[{"id":"j_1","capability":"health.query","params":{"metric":"hrv","from":"2026-10-15T00:00:00+08:00","interval":"hour"},"created_at":"2026-10-16T08:00:00+08:00"}],"poll_after_seconds":30}"#
        let resp = try JSONDecoder().decode(JobsResponse.self, from: Data(wire.utf8))
        #expect(resp.jobs.first?.params?["metric"] == .string("hrv"))
        #expect(resp.pollAfterSeconds == 30)

        let result = JobResult(jobId: "j_1", ok: true, result: .object(["count": .number(3)]), startedAt: "a", finishedAt: "b")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let out = String(decoding: try encoder.encode(ResultsRequest(device: "test-device", results: [result])), as: UTF8.self)
        #expect(out == #"{"device":"test-device","results":[{"finished_at":"b","job_id":"j_1","ok":true,"result":{"count":3},"started_at":"a"}]}"#)
    }

    @Test func healthQueryParamParsing() throws {
        let now = Date(timeIntervalSince1970: 1_792_108_800)
        let p = try HealthQueryParams(["metric": .string("hr"), "interval": .string("15m")], now: now)
        #expect(p.target == .quantity(.heartRate))
        #expect(p.to == now)
        #expect(p.from == now.addingTimeInterval(-86_400))
        #expect(p.interval == DateComponents(minute: 15))
        #expect(try HealthQueryParams(["metric": .string("sleep")], now: now).target == .sleep)
        #expect(throws: CapabilityError.self) { try HealthQueryParams(["metric": .string("bogus")], now: now) }
        #expect(throws: CapabilityError.self) { try HealthQueryParams([:], now: now) }
        #expect(throws: CapabilityError.self) {
            try HealthQueryParams(["metric": .string("steps"), "from": .string("2026-10-17"), "to": .string("2026-10-16")], now: now)
        }
    }

    @Test func boxURLValidation() throws {
        #expect(try BoxClient.validatedBaseURL(" https://example.com ").absoluteString == "https://example.com")
        #expect(try BoxClient.validatedBaseURL("http://localhost:8787").port == 8787)
        #expect(throws: BoxError.insecureURL) { try BoxClient.validatedBaseURL("http://example.com") }
        #expect(throws: BoxError.invalidURL) { try BoxClient.validatedBaseURL("not a url") }
    }
}
