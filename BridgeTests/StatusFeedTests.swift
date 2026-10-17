import Foundation
import Testing
@testable import Bridge

@Suite struct StatusFeedTests {
    private func entry(_ id: String, _ status: ActivityEntry.Status) -> ActivityEntry {
        ActivityEntry(id: id, time: Date(timeIntervalSince1970: 0), capability: "device.info", note: nil, status: status, summary: "s-\(id)")
    }

    @Test func filterChips() {
        let feed = [entry("1", .done), entry("2", .failed), entry("3", .running), entry("4", .failed)]
        #expect(ActivityFilter.all.apply(feed).count == 4)
        #expect(ActivityFilter.failed.apply(feed).map(\.id) == ["2", "4"])
        #expect(ActivityFilter.running.apply(feed).map(\.id) == ["3"])
    }

    @Test func copyDetailIsFullButBlobFree() throws {
        let photo = JobResult(jobId: "p", ok: true, result: .object([
            "width": .number(1024),
            "jpeg_base64": .string(String(repeating: "A", count: 40_000)),
            "items": .array([.object(["payload_base64": .string(String(repeating: "B", count: 4096))])]),
        ]), startedAt: "", finishedAt: "")
        let detail = ActivitySummary.detail(photo)
        #expect(detail.contains("\"width\" : 1024"))
        #expect(detail.contains("<jpeg_base64: 29 KB, left out of the copy>"))
        #expect(detail.contains("<payload_base64: 3 KB, left out of the copy>"))
        #expect(!detail.contains("AAAA"))

        let failed = JobResult(jobId: "f", ok: false, error: JobError(code: "cancelled", message: "Cancelled on the phone"), startedAt: "", finishedAt: "")
        #expect(ActivitySummary.detail(failed).contains("\"code\" : \"cancelled\""))
    }

    @Test func detailIsNeverPersisted() throws {
        var e = entry("1", .done)
        e.detail = "{\"phone\": \"+86…\"}"
        #expect(e.copyText == e.detail)
        let restored = try JSONDecoder().decode(ActivityEntry.self, from: JSONEncoder().encode(e))
        #expect(restored.detail == nil)
        #expect(restored.copyText == "s-1")
    }

    @Test func permissionButtons() {
        #expect(PermissionKind.camera.action(for: PermissionState.notAsked) == .ask)
        #expect(PermissionKind.camera.action(for: PermissionState.denied) == .openSettings)
        #expect(PermissionKind.camera.action(for: PermissionState.granted) == .none)
        #expect(PermissionKind.photos.action(for: "Limited") == .openSettings)
        #expect(PermissionKind.location.action(for: "When in use (keep-alive needs Always)") == .ask)
        #expect(PermissionKind.location.action(for: "Denied") == .openSettings)
        #expect(PermissionKind.health.action(for: "Prompt answered (read grants are private)") == .none)
        #expect(PermissionKind.home.action(for: "Not on the simulator") == .none)
        #expect(Set(PermissionKind.allCases.map(\.title)).count == PermissionKind.allCases.count)
    }

    @Test func everyPermissionHasItsUsageString() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
                    "NFCReaderUsageDescription", "NSHomeKitUsageDescription", "NSContactsUsageDescription",
                    "NSPhotoLibraryUsageDescription", "NSMotionUsageDescription", "NSLocationWhenInUseUsageDescription"] {
            #expect((info[key] as? String)?.isEmpty == false, "\(key) missing")
        }
        #expect(info["UIFileSharingEnabled"] as? Bool == true)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    }
}
