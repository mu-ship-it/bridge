import CoreNFC
import Foundation

/// Parsed `nfc.read` params: `timeout` (5–60 s, default 30; iOS ends any NFC scan at 60 s).
struct NFCReadParams: Sendable, Equatable {
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        timeout = try Params.int(params ?? [:], "timeout", in: 5...60) ?? 30
    }
}

/// `nfc.read` → iOS shows its "Ready to Scan" sheet; Mu holds the phone to an NFC tag.
/// Result: `{records: [{tnf, type, payload_base64, text?, uri?}]}` from the first NDEF message.
/// Mu cancelling is `ok:false`, code `cancelled`; nothing scanned in time is code `timeout`.
struct NFCReadCapability: Capability {
    let name = "nfc.read"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try NFCReadParams(job.params)
        guard NFCNDEFReaderSession.readingAvailable else {
            throw CapabilityError.unavailable("This device cannot read NFC tags (simulator?)")
        }
        try await MainActor.run { try Presenter.requireForeground() }
        let records = try await NFCReader().read(timeout: q.timeout)
        return .object(["records": .array(records)])
    }

    static func describe(_ record: NFCNDEFPayload) -> JSONValue {
        var o: [String: JSONValue] = [
            "tnf": .number(Double(record.typeNameFormat.rawValue)),
            "type": .string(String(decoding: record.type, as: UTF8.self)),
            "payload_base64": .string(record.payload.base64EncodedString()),
        ]
        if let uri = record.wellKnownTypeURIPayload() { o["uri"] = .string(uri.absoluteString) }
        if let text = record.wellKnownTypeTextPayload().0 { o["text"] = .string(text) }
        return .object(o)
    }
}

/// One NDEF scan. CoreNFC calls back on `queue`; ResumeOnce makes the first answer win.
private final class NFCReader: NSObject, NFCNDEFReaderSessionDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "nfc.read")
    private var once: ResumeOnce<[JSONValue]>?
    private var session: NFCNDEFReaderSession?

    func read(timeout: Int) async throws -> [JSONValue] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.once = ResumeOnce(continuation)
                    let session = NFCNDEFReaderSession(delegate: self, queue: self.queue, invalidateAfterFirstRead: true)
                    session.alertMessage = "白手套: hold the top of your iPhone near the tag."
                    self.session = session
                    session.begin()
                    self.queue.asyncAfter(deadline: .now() + .seconds(timeout)) {
                        self.once?.resume(.failure(CapabilityError.timedOut(timeout)))
                        self.session?.invalidate(errorMessage: "Timed out")
                    }
                }
            }
        } onCancel: {
            queue.async { self.session?.invalidate() }
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        once?.resume(.success(messages.first?.records.map(NFCReadCapability.describe) ?? []))
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        let mapped: Error = switch code {
        case .readerSessionInvalidationErrorUserCanceled?: CapabilityError.cancelled
        case .readerSessionInvalidationErrorSessionTimeout?: CapabilityError.timedOut(60)
        default: CapabilityError(code: "failed", message: "NFC: \(error.localizedDescription)")
        }
        // After a successful read iOS invalidates with "first NDEF tag read"; `once` ignores it.
        once?.resume(.failure(mapped))
        self.session = nil
    }
}
