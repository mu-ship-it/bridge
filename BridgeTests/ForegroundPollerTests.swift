import Foundation
import Testing
@testable import Bridge

@Suite struct ForegroundPollerTests {
    @Test func reissuesAtOnceAfterALongPollAnswers() {
        var policy = ForegroundPoller.Policy()
        #expect(policy.delay(after: .ran(jobs: 0), elapsed: 25) == 0)   // wait ran out
        #expect(policy.delay(after: .ran(jobs: 2), elapsed: 0.2) == 0)  // a job arrived
    }

    @Test func backsOffOnErrorsAndResetsOnSuccess() {
        var policy = ForegroundPoller.Policy()
        let delays = (0..<8).map { _ in policy.delay(after: .failed, elapsed: 0.1) }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
        #expect(policy.delay(after: .ran(jobs: 1), elapsed: 0.1) == 0)
        #expect(policy.failures == 0)
        #expect(policy.delay(after: .failed, elapsed: 0.1) == 2)
    }

    @Test func aBoxThatIgnoresWaitFallsBackToItsHint() {
        var policy = ForegroundPoller.Policy()
        #expect(policy.delay(after: .ran(jobs: 0), elapsed: 0.1, pollAfter: 30) == 30)
        #expect(policy.delay(after: .ran(jobs: 0), elapsed: 0.1) == 30)
    }

    @Test func waitsBrieflyWhenAnotherRoundIsRunning() {
        var policy = ForegroundPoller.Policy()
        #expect(policy.delay(after: .busy, elapsed: 0) == 1)
        #expect(policy.failures == 0)
    }

    @Test func longPollRequestCarriesWaitAndOutlastsIt() {
        let client = BoxClient(config: BridgeConfig(baseURL: URL(string: "https://box.example")!, token: "t", deviceId: "d"))
        let long = client.jobsRequest(wait: 25)
        #expect(long.url?.query == "device=d&wait=25")
        #expect(long.timeoutInterval == 40)
        let instant = client.jobsRequest(wait: nil)
        #expect(instant.url?.query == "device=d")
        #expect(instant.timeoutInterval == 30)
    }
}
