import AVFoundation
import NaturalLanguage

/// Parsed `speak` params: `text` (required, ≤ 4000 chars), `rate` (0–1, default 0.5 = normal),
/// `voice` (a voice identifier like `com.apple.voice.compact.zh-CN.Tingting`, or a language like
/// `zh-CN`; default: a voice for the text's own language).
struct SpeakParams: Sendable, Equatable {
    let text: String
    let rate: Float
    let voice: String?

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let t = try Params.string(p, "text") else { throw CapabilityError.badParams("'text' (string) is required") }
        guard t.count <= 4000 else { throw CapabilityError.badParams("'text' is too long (max 4000 characters)") }
        text = t
        rate = Float(try Params.double(p, "rate", in: 0...1) ?? Double(AVSpeechUtteranceDefaultSpeechRate))
        voice = try Params.string(p, "voice")
    }

    /// The voice to use: explicit identifier, explicit language, else the text's dominant language.
    func resolvedVoice() throws -> AVSpeechSynthesisVoice? {
        if let voice {
            if let v = AVSpeechSynthesisVoice(identifier: voice) ?? AVSpeechSynthesisVoice(language: voice) { return v }
            throw CapabilityError.badParams("No voice '\(voice)' on this phone. Use a language like zh-CN or en-US, or a voice identifier.")
        }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        return AVSpeechSynthesisVoice(language: Self.speechLanguage(language))
    }

    /// NaturalLanguage says `zh-Hans`; the synthesizer wants `zh-CN`.
    static func speechLanguage(_ language: NLLanguage) -> String {
        switch language {
        case .simplifiedChinese: "zh-CN"
        case .traditionalChinese: "zh-TW"
        default: language.rawValue
        }
    }
}

/// `speak` → reads `text` aloud and returns when it has finished: `{spoken: true, voice, seconds}`.
/// Plays even with the ring switch on silent (it was asked for out loud). Needs the app open:
/// iOS stops an app's audio once it is in the background.
struct SpeakCapability: Capability {
    let name = "speak"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try SpeakParams(job.params)
        let voice = try q.resolvedVoice()
        let started = Date()
        let used = try await Speaker.shared.speak(q.text, rate: q.rate, voice: voice)
        return .object([
            "spoken": .bool(true),
            "voice": used.map(JSONValue.string) ?? .null,
            "seconds": .number((Date().timeIntervalSince(started) * 10).rounded() / 10),
        ])
    }
}

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Returns the voice identifier used.
    func speak(_ text: String, rate: Float, voice: AVSpeechSynthesisVoice?) async throws -> String? {
        try Presenter.requireForeground()
        guard finished == nil else { throw CapabilityError.unavailable("Already speaking") }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        defer { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + rate * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
        utterance.voice = voice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finished = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.synthesizer.stopSpeaking(at: .immediate) }
        }
        return utterance.voice?.identifier
    }

    private func end(_ result: Result<Void, Error>) {
        finished?.resume(with: result)
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(.success(())) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(.failure(CancellationError())) }
    }
}
