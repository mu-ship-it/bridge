import Foundation
import Testing
@testable import Bridge

/// v0.3 capabilities: param validation, URL building, the Documents store, and the clean
/// `unavailable` answer on the simulator for everything that needs real hardware.
@Suite struct PhoneCapabilityTests {
    private func code(_ capability: any Capability, _ params: [String: JSONValue]? = nil) async -> String? {
        let r = await JobDispatcher([capability]).dispatch(Job(id: "t", capability: capability.name, params: params))
        return r.error?.code
    }

    // MARK: camera / mic / speak

    @Test func cameraCapture() throws {
        let d = try CameraCaptureParams(nil)
        #expect(d == (try CameraCaptureParams(["facing": .string("back"), "max_px": .number(1024), "timeout": .number(90)])))
        #expect(!d.front && d.maxPx == 1024 && d.timeout == Presenter.defaultTimeout)
        #expect(try CameraCaptureParams(["facing": .string("Front")]).front)
        #expect(try CameraCaptureParams(["max_px": .number(99_999), "timeout": .number(600)]).maxPx == 4096)
        #expect(try CameraCaptureParams(["timeout": .number(600)]).timeout == Presenter.maxTimeout)
        #expect(throws: CapabilityError.self) { try CameraCaptureParams(["facing": .string("sideways")]) }
        #expect(throws: CapabilityError.self) { try CameraCaptureParams(["max_px": .string("big")]) }
    }

    @Test func interactiveTimeoutStaysInsideTheLease() {
        #expect(Presenter.maxTimeout < 120)
    }

    @Test func micRecord() throws {
        let d = try MicRecordParams(nil)
        #expect(d.seconds == 10 && d.transcribe && d.audio && d.locale == .current)
        #expect(try MicRecordParams(["seconds": .number(600)]).seconds == 60)
        #expect(try MicRecordParams(["locale": .string("zh-CN")]).locale.identifier == "zh-CN")
        #expect(try MicRecordParams(["transcribe": .bool(false)]).transcribe == false)
        #expect(throws: CapabilityError.self) { try MicRecordParams(["transcribe": .bool(false), "audio": .bool(false)]) }
        #expect(throws: CapabilityError.self) { try MicRecordParams(["locale": .string("../etc")]) }
        #expect(throws: CapabilityError.self) { try MicRecordParams(["seconds": .string("long")]) }
    }

    @Test func speak() throws {
        let p = try SpeakParams(["text": .string("你好，Mu。火车十一点半出发。")])
        #expect(p.rate == 0.5 && p.voice == nil)
        #expect(try p.resolvedVoice()?.language.hasPrefix("zh") ?? true)   // nil only if no zh voice installed
        #expect(try SpeakParams(["text": .string("hi"), "rate": .number(3)]).rate == 1)
        #expect(throws: CapabilityError.self) { try SpeakParams([:]) }
        #expect(throws: CapabilityError.self) { try SpeakParams(["text": .string("   ")]) }
        #expect(throws: CapabilityError.self) { try SpeakParams(["text": .string(String(repeating: "x", count: 4001))]) }
        #expect(throws: CapabilityError.self) { try SpeakParams(["text": .string("hi"), "voice": .string("no-such-voice")]).resolvedVoice() }
        #expect(SpeakParams.speechLanguage(.simplifiedChinese) == "zh-CN")
    }

    // MARK: haptic / torch / brightness

    @Test func deviceControls() throws {
        #expect(try HapticParams(nil).style == "medium")
        #expect(try HapticParams(["style": .string("SUCCESS")]).style == "success")
        #expect(throws: CapabilityError.self) { try HapticParams(["style": .string("buzz")]) }

        #expect(try TorchParams(["on": .bool(true)]) == TorchParams(["on": .bool(true), "level": .number(1)]))
        #expect(try TorchParams(["on": .bool(true), "level": .number(0)]).level == 0.01)
        #expect(throws: CapabilityError.self) { try TorchParams([:]) }
        #expect(throws: CapabilityError.self) { try TorchParams(["on": .string("bright")]) }

        #expect(try ScreenBrightnessParams(["level": .number(1.7)]).level == 1)
        #expect(throws: CapabilityError.self) { try ScreenBrightnessParams(nil) }
    }

    // MARK: open.url / shortcuts.run / settings.open / call

    @Test func openURL() throws {
        #expect(try OpenURLParams(["url": .string("maps://?q=Shanghai")]).url.scheme == "maps")
        #expect(try OpenURLParams(["url": .string("weixin://")]).url.scheme == "weixin")
        #expect(throws: CapabilityError.self) { try OpenURLParams(["url": .string("not a url")]) }
        #expect(throws: CapabilityError.self) { try OpenURLParams(["url": .string("/relative/path")]) }
        #expect(throws: CapabilityError.self) { try OpenURLParams(nil) }
    }

    @Test func shortcutsRunURLEncodesEverything() throws {
        let plain = try ShortcutsRunParams(["name": .string("白手套 Focus on")])
        #expect(plain.url.absoluteString == "shortcuts://run-shortcut?name=%E7%99%BD%E6%89%8B%E5%A5%97%20Focus%20on")
        let withInput = try ShortcutsRunParams(["name": .string("Log"), "input": .string("a+b&c=d")])
        #expect(withInput.url.absoluteString == "shortcuts://run-shortcut?name=Log&input=text&text=a%2Bb%26c%3Dd")
        let json = try ShortcutsRunParams(["name": .string("Log"), "input": .object(["n": .number(1)])])
        #expect(json.input == #"{"n":1}"#)
        #expect(throws: CapabilityError.self) { try ShortcutsRunParams(["input": .string("x")]) }
    }

    @Test func settingsOpen() throws {
        #expect(try SettingsOpenParams(nil).section == "app")
        #expect(try SettingsOpenParams(["section": .string("WiFi")]).url.absoluteString == "App-prefs:WIFI")
        for section in ["wifi", "bluetooth", "notifications", "privacy", "battery", "display", "focus", "app"] {
            #expect(SettingsOpenParams.sections[section] != nil, "missing \(section)")
        }
        #expect(throws: CapabilityError.self) { try SettingsOpenParams(["section": .string("secret")]) }
    }

    @Test func callAndRecipients() throws {
        #expect(try CallParams(["number": .string("+86 (21) 1234-5678")]).url.absoluteString == "tel:+862112345678")
        #expect(try CallParams(["number": .string("10086,1#")]).url.absoluteString == "tel:10086,1%23")
        #expect(throws: CapabilityError.self) { try CallParams(["number": .string("call mom")]) }
        #expect(throws: CapabilityError.self) { try CallParams(["number": .string("12")]) }

        #expect(try ComposeSMSParams(["to": .string("+8613800000000, mu@example.com"), "body": .string("hi")]).to.count == 2)
        #expect(try ComposeSMSParams(["to": .array([.string("10086")])]).body == "")
        #expect(throws: CapabilityError.self) { try ComposeSMSParams(["body": .string("hi")]) }
        #expect(throws: CapabilityError.self) { try ComposeSMSParams(["to": .string("nobody")]) }
        #expect(throws: CapabilityError.self) { try ComposeSMSParams(["to": .array(Array(repeating: .string("10086"), count: 21))]) }

        let mail = try ComposeMailParams(["to": .string("a@example.com"), "subject": .string("s"), "body": .string("b")])
        #expect(mail.to == ["a@example.com"] && mail.cc.isEmpty && !mail.html)
        #expect(throws: CapabilityError.self) { try ComposeMailParams(["to": .string("+8613800000000")]) }
        #expect(throws: CapabilityError.self) { try ComposeMailParams(["to": .string("a@example.com"), "cc": .number(1)]) }
    }

    // MARK: files

    @Test func fileNamesAndWriteParams() throws {
        #expect(try FileStore.validName(["name": .string("notes 2026.txt")]) == "notes 2026.txt")
        for bad in ["../escape.txt", "a/b.txt", ".hidden", "", "c:d"] {
            #expect(throws: CapabilityError.self, "\(bad)") { try FileStore.validName(["name": .string(bad)]) }
        }
        #expect(try FilesWriteParams(["name": .string("a.txt"), "text": .string("hi")]).data == Data("hi".utf8))
        #expect(try FilesWriteParams(["name": .string("a.bin"), "base64": .string("AAEC")]).data == Data([0, 1, 2]))
        #expect(throws: CapabilityError.self) { try FilesWriteParams(["name": .string("a"), "text": .string("x"), "base64": .string("AA==")]) }
        #expect(throws: CapabilityError.self) { try FilesWriteParams(["name": .string("a")]) }
        #expect(throws: CapabilityError.self) { try FilesWriteParams(["name": .string("a"), "base64": .string("%%%")]) }
    }

    @Test func filesRoundTripInATempFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(root: root)
        let dispatcher = JobDispatcher([FilesWriteCapability(store: store), FilesReadCapability(store: store), FilesListCapability(store: store)])

        let w = await dispatcher.dispatch(Job(id: "1", capability: "files.write", params: ["name": .string("b.txt"), "text": .string("你好")]))
        #expect(w.ok && w.result?["size"] == .number(6))
        _ = await dispatcher.dispatch(Job(id: "2", capability: "files.write", params: ["name": .string("b.txt"), "text": .string("!"), "append": .bool(true)]))
        _ = await dispatcher.dispatch(Job(id: "3", capability: "files.write", params: ["name": .string("a.bin"), "base64": .string("/w==")]))

        let text = await dispatcher.dispatch(Job(id: "4", capability: "files.read", params: ["name": .string("b.txt")]))
        #expect(text.result?["text"] == .string("你好!"))
        let binary = await dispatcher.dispatch(Job(id: "5", capability: "files.read", params: ["name": .string("a.bin")]))
        #expect(binary.result?["base64"] == .string("/w==") && binary.result?["text"] == nil)
        let missing = await dispatcher.dispatch(Job(id: "6", capability: "files.read", params: ["name": .string("nope.txt")]))
        #expect(missing.error?.code == "not_found")

        let list = await dispatcher.dispatch(Job(id: "7", capability: "files.list"))
        #expect(list.result?["count"] == .number(2))
        #expect(list.result?["files"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["a.bin", "b.txt"])
    }

    @Test func shareNeedsSomethingToShare() throws {
        #expect(throws: CapabilityError.self) { try ShareParams([:]) }
        #expect(throws: CapabilityError.self) { try ShareParams(["file": .string("../x")]) }
        #expect(try ShareParams(["text": .string("hi"), "url": .string("https://example.com")]).url != nil)
    }

    // MARK: nfc / sensors

    @Test func nfcAndSensors() throws {
        #expect(try NFCReadParams(nil).timeout == 30)
        #expect(try NFCReadParams(["timeout": .number(300)]).timeout == 60)
        #expect(try SensorsSampleParams(nil) == SensorsSampleParams(["seconds": .number(2), "hz": .number(10)]))
        #expect(try SensorsSampleParams(["seconds": .number(99), "hz": .number(0)]) == SensorsSampleParams(["seconds": .number(10), "hz": .number(1)]))
        #expect(throws: CapabilityError.self) { try SensorsSampleParams(["hz": .string("fast")]) }
    }

    @Test func feedSummariesNeverCarryPayloads() {
        let ok = { (r: JSONValue) in JobResult(jobId: "s", ok: true, result: r, startedAt: "", finishedAt: "") }
        let photo = ok(.object(["jpeg_base64": .string(String(repeating: "A", count: 5000)), "width": .number(1024), "height": .number(768)]))
        #expect(ActivitySummary.summarize(Job(id: "s", capability: "camera.capture"), photo) == "photo 1024×768")
        let sms = ok(.object(["shown": .bool(true), "user_action": .string("sent")]))
        #expect(ActivitySummary.summarize(Job(id: "s", capability: "compose.sms"), sms) == "sheet shown · sent")
        let opened = ok(.object(["opened": .bool(true)]))
        #expect(ActivitySummary.summarize(Job(id: "s", capability: "settings.open", params: ["section": .string("wifi")]), opened) == "opened wifi")
    }

    // MARK: simulator

    #if targetEnvironment(simulator)
    @Test func hardwareCapabilitiesAreCleanlyUnavailableOnTheSimulator() async {
        #expect(await code(CameraCaptureCapability()) == "unavailable")
        #expect(await code(BarcodeScanCapability()) == "unavailable")
        #expect(await code(TorchCapability(), ["on": .bool(true)]) == "unavailable")
        #expect(await code(NFCReadCapability()) == "unavailable")
        #expect(await code(WiFiInfoCapability()) == "unavailable")
        #expect(await code(CallCapability(), ["number": .string("10086")]) == "unavailable")
        #expect(await code(ComposeSMSCapability(), ["to": .string("10086")]) == "unavailable")
        #expect(await code(ComposeMailCapability(), ["to": .string("a@example.com")]) == "unavailable")
        #expect(await code(SensorsSampleCapability(), ["seconds": .number(1)]) == "unavailable")
    }

    @Test func badParamsWinOverHardwareChecks() async {
        #expect(await code(TorchCapability()) == "bad_params")
        #expect(await code(CameraCaptureCapability(), ["facing": .string("up")]) == "bad_params")
    }
    #endif
}
