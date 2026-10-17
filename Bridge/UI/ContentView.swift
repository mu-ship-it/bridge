import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Status", systemImage: "antenna.radiowaves.left.and.right") { StatusView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        // Foreground connection: long poll while the app is active. Leaving .active cancels the
        // task, which cancels the in-flight request — nothing polls once the app is hidden.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await AppStatus.shared.refreshPermissions()
            await ForegroundPoller(loop: BridgeRuntime.shared.jobLoop).run()
        }
    }
}
