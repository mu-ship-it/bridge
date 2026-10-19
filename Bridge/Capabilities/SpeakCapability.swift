import AVFoundation
import NaturalLanguage

/// Parsed `speak` params: `text` (required, ≤ 4000 chars), `rate` (0–1, default 0.5 = normal),
/// `voice` (a voice identifier like `com.apple.voice.compact.zh-CN.Tingting`, or a language like
/// `zh-CN`; default: the text's own language). For a language, the best installed voice wins:
/// premium > enhanced > compact.
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

    /// The voice to use: explicit identifier, else the best voice for an explicit language, else
    /// the best voice for the text's dominant language.
    func resolvedVoice(installed: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) throws -> AVSpeechSynthesisVoice? {
        let candidates = installed.map(VoiceCandidate.init)
        if let voice {
            if let v = AVSpeechSynthesisVoice(identifier: voice) { return v }
            if let best = VoiceCandidate.best(for: voice, among: candidates),
               let v = installed.first(where: { $0.identifier == best.identifier }) { return v }
            if let v = AVSpeechSynthesisVoice(language: voice) { return v }
            throw CapabilityError.badParams("No voice '\(voice)' on this phone. Use a language like zh-CN or en-US, or a voice identifier.")
        }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        let code = Self.speechLanguage(language)
        if let best = VoiceCandidate.best(for: code, among: candidates),
           let v = installed.first(where: { $0.identifier == best.identifier }) { return v }
        return AVSpeechSynthesisVoice(language: code)
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

/// One installed voice, reduced to what choosing needs. Pure, so the ranking is unit-tested.
struct VoiceCandidate: Sendable, Equatable {
    enum Quality: Int, Sendable, Comparable {
        case compact = 1, enhanced, premium
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        var label: String { String(describing: self) }
    }

    let identifier: String
    let name: String
    let language: String
    let quality: Quality
    /// Novelty voices (Bells, Zarvox…) and the user's Personal Voice are never picked automatically.
    var special = false

    init(identifier: String, name: String, language: String, quality: Quality, special: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.special = special
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality = switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .compact
        }
        self.init(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality,
                  special: !voice.voiceTraits.isDisjoint(with: [.isNoveltyVoice, .isPersonalVoice]))
    }

    /// The best voice for `language` ("zh-CN" exact first; "zh" or "en" matches any region):
    /// highest quality, then exact region, then name for a stable pick. nil = none installed.
    static func best(for language: String, among voices: [VoiceCandidate]) -> VoiceCandidate? {
        let wanted = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        let matching = voices.filter { voice in
            let lang = voice.language.lowercased()
            return !voice.special && (lang == wanted || lang.split(separator: "-").first.map(String.init) == base)
        }
        return matching.max { a, b in
            if a.quality != b.quality { return a.quality < b.quality }
            let aExact = a.language.lowercased() == wanted, bExact = b.language.lowercased() == wanted
            if aExact != bExact { return !aExact }
            return a.name > b.name
        }
    }
}

/// `speak` → reads `text` aloud and returns when it has finished:
/// `{spoken: true, voice, voice_name, voice_quality, voice_language, seconds}`.
/// Plays even with the ring switch on silent (it was asked for out loud). Needs the app open:
/// iOS stops an app's audio once it is in the background.
struct SpeakCapability: Capability {
    let name = "speak"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try SpeakParams(job.params)
        let voice = try q.resolvedVoice()
        let started = Date()
        let used = try await Speaker.shared.speak(q.text, rate: q.rate, voice: voice)
        let info = voice.map(VoiceCandidate.init)
        return .object([
            "spoken": .bool(true),
            "voice": used.map(JSONValue.string) ?? .null,
            "voice_name": info.map { .string($0.name) } ?? .null,
            "voice_quality": info.map { .string($0.quality.label) } ?? .null,
            "voice_language": info.map { .string($0.language) } ?? .null,
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
