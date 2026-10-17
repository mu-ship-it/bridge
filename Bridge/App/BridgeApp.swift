import SwiftUI
import UIKit
import UserNotifications

@main
struct BridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTasks.register()
        UNUserNotificationCenter.current().delegate = self
        BridgeRuntime.shared.start()
        // Silent (content-available) pushes don't need the user notification prompt.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await BridgeRuntime.shared.registerPushToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppStatus.shared.setPushState("APNs unavailable: \(error.localizedDescription)")
    }

    /// Show `notify.show` banners even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Silent push (`"aps":{"content-available":1}`) → one job poll.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let wantsSync = (userInfo["bridge"] as? String) == "sync"
        return await BridgeRuntime.shared.handleSilentPush(wantsSync: wantsSync) ? .newData : .noData
    }
}
