import AVFoundation
import Contacts
import CoreMotion
import EventKit
import Photos
import Speech
import UIKit
import UserNotifications

/// Every permission 白手套 can use, for the Status screen's Permissions section: what it is for,
/// its state in plain words, and how to ask. iOS asks only once, so after a "Don't Allow" the
/// button becomes "Open Settings".
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case health, location, notifications, calendar, reminders, contacts, photos, motion
    case camera, microphone, speech, home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: "Health"
        case .location: "Location"
        case .notifications: "Notifications"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .motion: "Motion & Fitness"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .home: "Home"
        }
    }

    /// The capabilities that need it.
    var usedBy: String {
        switch self {
        case .health: "health.query, health sync"
        case .location: "location.now, wifi.info, waking on significant moves"
        case .notifications: "notify.show, agent.say {notify}"
        case .calendar: "calendar.events"
        case .reminders: "reminders.list, reminders.add"
        case .contacts: "contacts.search"
        case .photos: "photos.recent"
        case .motion: "motion.today, sensors.sample barometer"
        case .camera: "camera.capture, barcode.scan"
        case .microphone: "mic.record"
        case .speech: "mic.record {transcribe}"
        case .home: "home.list, home.get, home.set"
        }
    }

    @MainActor
    func state() async -> String {
        switch self {
        case .health: return await HealthService.shared.authorizationSummary()
        case .location: return LocationService.shared.authorizationDescription
        case .notifications:
            return switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: PermissionState.granted
            case .notDetermined: PermissionState.notAsked
            default: PermissionState.denied
            }
        case .calendar: return Self.describe(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return Self.describe(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            return switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: PermissionState.granted
            case .limited: "Limited"
            case .notDetermined: PermissionState.notAsked
            case .restricted: PermissionState.restricted
            default: PermissionState.denied
            }
        case .photos:
            return switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: PermissionState.granted
            case .limited: "Limited"
            case .notDetermined: PermissionState.notAsked
            case .restricted: PermissionState.restricted
            default: PermissionState.denied
            }
        case .motion:
            return switch CMPedometer.authorizationStatus() {
            case .authorized: PermissionState.granted
            case .notDetermined: PermissionState.notAsked
            case .restricted: PermissionState.restricted
            default: PermissionState.denied
            }
        case .camera: return CameraAccess.state
        case .microphone: return MicRecordCapability.microphoneState
        case .speech: return MicRecordCapability.speechState
        case .home: return HomeStore.shared.state
        }
    }

    /// Shows iOS' own prompt (only possible while it has never been answered).
    @MainActor
    func request() async {
        switch self {
        case .health: try? await HealthService.shared.requestAuthorization()
        case .location: LocationService.shared.requestAuthorization()
        case .notifications: _ = try? await NotifyShowCapability.requestAuthorization()
        case .calendar: _ = await EventKitAccess.requestCalendar()
        case .reminders: _ = await EventKitAccess.requestReminders()
        case .contacts: _ = await ContactsSearchCapability.requestAuthorization()
        case .photos: _ = await PhotosRecentCapability.requestAuthorization()
        case .motion: await MotionTodayCapability.requestAuthorization()
        case .camera: await CameraAccess.requestAuthorization()
        case .microphone: await MicRecordCapability.requestMicrophone()
        case .speech: await MicRecordCapability.requestSpeech()
        case .home: HomeStore.shared.requestAuthorization()
        }
    }

    /// Which button a row gets for a given state.
    enum Action: Equatable { case ask, openSettings, none }

    func action(for state: String) -> Action {
        switch self {
        case .health:
            // iOS keeps Health read grants private; after the prompt, changes happen in the Health app.
            return state == "Not requested yet" ? .ask : .none
        case .location:
            if state == "Not requested yet" || state.hasPrefix("When in use") { return .ask }   // second ask escalates to Always
            return state == "Denied" ? .openSettings : .none
        default:
            switch state {
            case PermissionState.notAsked: return .ask
            case PermissionState.denied, "Limited", "Write only": return .openSettings
            default: return .none
            }
        }
    }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: PermissionState.granted
        case .writeOnly: "Write only"
        case .notDetermined: PermissionState.notAsked
        case .restricted: PermissionState.restricted
        default: PermissionState.denied
        }
    }
}
