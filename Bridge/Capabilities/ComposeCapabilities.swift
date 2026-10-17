import MessageUI
import UIKit

// iOS never lets an app send a message, send an email or place a call by itself. These
// capabilities fill in Apple's own sheet; Mu reads it and taps Send / Call — or doesn't.
// `shown: true` is all the app can promise. For SMS and mail iOS also says which button Mu
// pressed, reported as `user_action`; the app itself has sent nothing either way.

/// One or many recipients: a string or an array of strings (1–20).
enum Recipients {
    static func parse(_ p: [String: JSONValue], _ key: String, required: Bool, check: (String) -> Bool) throws -> [String] {
        let raw: [JSONValue]
        switch p[key] {
        case nil, .null?:
            if required { throw CapabilityError.badParams("'\(key)' is required") }
            return []
        case .string(let s)?: raw = s.split(separator: ",").map { .string(String($0)) }
        case .array(let a)?: raw = a
        default: throw CapabilityError.badParams("'\(key)' must be a string or an array of strings")
        }
        let list = try raw.map { value -> String in
            guard case .string(let s) = value else { throw CapabilityError.badParams("'\(key)' must contain strings") }
            let t = s.trimmingCharacters(in: .whitespaces)
            guard check(t) else { throw CapabilityError.badParams("'\(key)': '\(t)' does not look right") }
            return t
        }
        guard (required ? 1 : 0)...20 ~= list.count else { throw CapabilityError.badParams("'\(key)': 1–20 recipients") }
        return list
    }

    static func isPhoneOrEmail(_ s: String) -> Bool { isEmail(s) || PhoneNumber.isValid(s) }
    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}

enum PhoneNumber {
    /// Digits plus the characters a dialer accepts; at least 3 digits.
    static func isValid(_ s: String) -> Bool {
        s.range(of: #"^\+?[0-9 ()\-.*#,;]+$"#, options: .regularExpression) != nil
            && s.filter(\.isNumber).count >= 3
    }
}

/// Parsed `compose.sms` params: `to` (number/email or list), `body` (≤ 5000 chars), `timeout`.
struct ComposeSMSParams: Sendable, Equatable {
    let to: [String]
    let body: String
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        to = try Recipients.parse(p, "to", required: true, check: Recipients.isPhoneOrEmail)
        body = try Params.string(p, "body") ?? ""
        guard body.count <= 5000 else { throw CapabilityError.badParams("'body' is too long (max 5000 characters)") }
        timeout = try Presenter.timeout(p)
    }
}

/// `compose.sms` {to, body} → Messages sheet, pre-filled: `{shown: true, user_action: sent|cancelled|failed}`.
struct ComposeSMSCapability: Capability {
    let name = "compose.sms"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ComposeSMSParams(job.params)
        guard await MFMessageComposeViewController.canSendText() else {
            throw CapabilityError.unavailable("This device cannot send messages (simulator, or no SIM / iMessage)")
        }
        let action: String = try await Presenter.present(timeout: q.timeout) { session in
            let sheet = MFMessageComposeViewController()
            sheet.recipients = q.to
            sheet.body = q.body
            let delegate = MessageDelegate(session)
            sheet.messageComposeDelegate = delegate
            session.keepAlive = delegate
            return sheet
        }
        return .object(["shown": .bool(true), "user_action": .string(action)])
    }

    @MainActor
    private final class MessageDelegate: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        let session: PresentedSession<String>
        init(_ session: PresentedSession<String>) { self.session = session }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            session.succeed(result == .sent ? "sent" : result == .cancelled ? "cancelled" : "failed")
        }
    }
}

/// Parsed `compose.mail` params: `to` (address or list), `cc?`, `subject?`, `body?`, `html?` (default false), `timeout`.
struct ComposeMailParams: Sendable, Equatable {
    let to: [String]
    let cc: [String]
    let subject: String
    let body: String
    let html: Bool
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        to = try Recipients.parse(p, "to", required: true, check: Recipients.isEmail)
        cc = try Recipients.parse(p, "cc", required: false, check: Recipients.isEmail)
        subject = try Params.string(p, "subject") ?? ""
        body = try Params.string(p, "body") ?? ""
        guard subject.count <= 500, body.count <= 100_000 else { throw CapabilityError.badParams("'subject' or 'body' is too long") }
        html = try Params.bool(p, "html") ?? false
        timeout = try Presenter.timeout(p)
    }
}

/// `compose.mail` {to, subject, body} → Mail sheet, pre-filled: `{shown: true, user_action: sent|saved|cancelled|failed}`.
struct ComposeMailCapability: Capability {
    let name = "compose.mail"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ComposeMailParams(job.params)
        guard await MFMailComposeViewController.canSendMail() else {
            throw CapabilityError.unavailable("No Mail account is set up on this device (or simulator)")
        }
        let action: String = try await Presenter.present(timeout: q.timeout) { session in
            let sheet = MFMailComposeViewController()
            sheet.setToRecipients(q.to)
            if !q.cc.isEmpty { sheet.setCcRecipients(q.cc) }
            sheet.setSubject(q.subject)
            sheet.setMessageBody(q.body, isHTML: q.html)
            let delegate = MailDelegate(session)
            sheet.mailComposeDelegate = delegate
            session.keepAlive = delegate
            return sheet
        }
        return .object(["shown": .bool(true), "user_action": .string(action)])
    }

    @MainActor
    private final class MailDelegate: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let session: PresentedSession<String>
        init(_ session: PresentedSession<String>) { self.session = session }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            let action = switch result {
            case .sent: "sent"
            case .saved: "saved"
            case .cancelled: "cancelled"
            default: "failed"
            }
            session.succeed(action)
        }
    }
}

/// Parsed `call` params: `number` (digits, `+`, spaces, `()-.*#,;`).
struct CallParams: Sendable, Equatable {
    let number: String

    init(_ params: [String: JSONValue]?) throws {
        guard let number = try Params.string(params ?? [:], "number") else { throw CapabilityError.badParams("'number' (string) is required") }
        guard PhoneNumber.isValid(number) else { throw CapabilityError.badParams("'number' does not look like a phone number") }
        self.number = number
    }

    /// `tel:` URL with formatting removed; `*`, `#`, `,` and `;` kept (and escaped) for extensions and codes.
    var url: URL {
        let dialable = number.filter { !" ()-.".contains($0) }
        var allowed = CharacterSet.decimalDigits
        allowed.insert(charactersIn: "+,;")
        return URL(string: "tel:" + (dialable.addingPercentEncoding(withAllowedCharacters: allowed) ?? dialable))!
    }
}

/// `call` {number} → iOS shows its "Call …?" prompt; Mu taps Call or Cancel: `{shown}`.
/// Whether the call was placed is never reported to apps.
struct CallCapability: Capability {
    let name = "call"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try CallParams(job.params)
        #if targetEnvironment(simulator)
        _ = q
        throw CapabilityError.unavailable("The simulator cannot place calls")
        #else
        return .object(["shown": .bool(try await URLOpener.open(q.url))])
        #endif
    }
}
