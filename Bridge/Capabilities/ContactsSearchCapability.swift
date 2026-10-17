@preconcurrency import Contacts
import Foundation

/// Parsed `contacts.search` params: `query` (required; a name, email or phone number), `limit` (1–20, default 20).
struct ContactsSearchParams: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case name, email, phone }

    let query: String
    let kind: Kind
    let limit: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let q = try Params.string(p, "query") else { throw CapabilityError.badParams("'query' is required") }
        query = q
        limit = try Params.int(p, "limit", in: 1...20) ?? 20
        let digits = q.filter(\.isNumber)
        if q.contains("@") {
            kind = .email
        } else if digits.count >= 5, q.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) {
            kind = .phone
        } else {
            kind = .name
        }
    }
}

/// `contacts.search` {query} → `{count, contacts: [{name, phones[], emails[]}]}` (max 20).
struct ContactsSearchCapability: Capability {
    let name = "contacts.search"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try ContactsSearchParams(job.params)
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        case .notDetermined: throw CapabilityError.permissionMissing("Contacts")
        default: throw CapabilityError.permissionDenied("Contacts")
        }
        let predicate: NSPredicate = switch q.kind {
        case .name: CNContact.predicateForContacts(matchingName: q.query)
        case .email: CNContact.predicateForContacts(matchingEmailAddress: q.query)
        case .phone: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: q.query))
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let found: [CNContact]
        do {
            found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw CapabilityError.unavailable("Contacts unavailable: \(error.localizedDescription)")
        }
        let contacts = found.prefix(q.limit).map { c -> JSONValue in
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName
            return .object([
                "name": .string(name),
                "phones": .array(c.phoneNumbers.map { .string($0.value.stringValue) }),
                "emails": .array(c.emailAddresses.map { .string($0.value as String) }),
            ])
        }
        return .object(["count": .number(Double(contacts.count)), "contacts": .array(Array(contacts))])
    }

    static func requestAuthorization() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }
}
