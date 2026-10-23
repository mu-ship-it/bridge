import Foundation

extension String {
    /// This fixed English word or phrase (a state, a title) in the reader's language, for display
    /// only: the value itself stays English, because it is compared in code and some of it goes to
    /// the box (heartbeat `connection`). A plain catalog lookup — no format specifiers are applied,
    /// so it is safe on any string; one with no translation comes back unchanged.
    var localizedForDisplay: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}
