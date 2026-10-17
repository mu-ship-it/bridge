import AVFoundation
import Speech

/// The three words the Status screen uses for every permission.
enum PermissionState {
    static let granted = "Granted"
    static let denied = "Denied"
    static let notAsked = "Not asked"
    static let restricted = "Restricted"

    static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: granted
        case .notDetermined: notAsked
        case .restricted: restricted
        default: denied
        }
    }

    static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: granted
        case .notDetermined: notAsked
        case .restricted: restricted
        default: denied
        }
    }

    static func describe(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted: granted
        case .undetermined: notAsked
        default: denied
        }
    }
}
