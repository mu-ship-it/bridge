import AVFoundation
import Speech

/// Parsed `mic.record` params: `seconds` (1–60, default 10), `transcribe` (default true),
/// `audio` (default true: include the m4a), `locale` (e.g. `zh-CN`; default the phone's).
struct MicRecordParams: Sendable, Equatable {
    let seconds: Int
    let transcribe: Bool
    let audio: Bool
    let locale: Locale

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        seconds = try Params.int(p, "seconds", in: 1...60) ?? 10
        transcribe = try Params.bool(p, "transcribe") ?? true
        audio = try Params.bool(p, "audio") ?? true
        guard transcribe || audio else { throw CapabilityError.badParams("Nothing to return: 'transcribe' and 'audio' are both false") }
        if let id = try Params.string(p, "locale") {
            guard id.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                throw CapabilityError.badParams("'locale' must look like en-US or zh-CN")
            }
            locale = Locale(identifier: id)
        } else {
            locale = .current
        }
    }
}

/// `mic.record` → records from the microphone (iOS shows its orange dot), then optionally
/// transcribes with Apple's speech recognizer — on-device when the locale supports it.
/// Result: `{seconds, m4a_base64?, transcript?, on_device?, locale?, transcript_error?}`.
/// A transcription problem does not lose the recording: it comes back as `transcript_error`.
struct MicRecordCapability: Capability {
    let name = "mic.record"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try MicRecordParams(job.params)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .undetermined: throw CapabilityError.permissionMissing("Microphone")
        default: throw CapabilityError.permissionDenied("Microphone")
        }
        try await MainActor.run { try Presenter.requireForeground() }

        let url = FileManager.default.temporaryDirectory.appending(path: "mic-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.record(to: url, seconds: q.seconds)

        var o: [String: JSONValue] = ["seconds": .number(Double(q.seconds))]
        if q.audio {
            o["m4a_base64"] = .string(try Data(contentsOf: url).base64EncodedString())
        }
        if q.transcribe {
            do {
                let t = try await Self.transcribe(url, locale: q.locale)
                o["transcript"] = .string(t.text)
                o["on_device"] = .bool(t.onDevice)
                o["locale"] = .string(q.locale.identifier)
            } catch let error as CapabilityError {
                o["transcript_error"] = .object(["code": .string(error.code), "message": .string(error.message)])
            }
        }
        return .object(o)
    }

    @MainActor
    private static func record(to url: URL, seconds: Int) async throws {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
        } catch {
            throw CapabilityError.unavailable("Microphone is busy or missing: \(error.localizedDescription)")
        }
        defer { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw CapabilityError.unavailable("Cannot record: \(error.localizedDescription)")
        }
        guard recorder.record(forDuration: TimeInterval(seconds)) else {
            throw CapabilityError.unavailable("The microphone did not start recording")
        }
        do {
            try await Task.sleep(for: .seconds(seconds) + .milliseconds(300))
        } catch {
            recorder.stop()
            throw error
        }
        recorder.stop()
    }

    private static func transcribe(_ url: URL, locale: Locale) async throws -> (text: String, onDevice: Bool) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined: throw CapabilityError.permissionMissing("Speech Recognition")
        default: throw CapabilityError.permissionDenied("Speech Recognition")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw CapabilityError.unavailable("No speech recognizer for \(locale.identifier)")
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        guard onDevice || recognizer.isAvailable else {
            throw CapabilityError.unavailable("Speech recognition for \(locale.identifier) needs a network connection")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        let text: String = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.resume(.success(result.bestTranscription.formattedString))
                } else if let error {
                    // "No speech detected" arrives as an error; for a recording that is just silence.
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
                        once.resume(.success(""))
                    } else {
                        once.resume(.failure(CapabilityError(code: "failed", message: "Transcription failed: \(error.localizedDescription)")))
                    }
                }
            }
        }
        return (text, onDevice)
    }

    @discardableResult
    static func requestMicrophone() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    @discardableResult
    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    static var microphoneState: String { PermissionState.describe(AVAudioApplication.shared.recordPermission) }
    static var speechState: String { PermissionState.describe(SFSpeechRecognizer.authorizationStatus()) }
}

/// Resumes a continuation at most once; callbacks from Apple frameworks may fire more than once.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
