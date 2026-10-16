import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Status", systemImage: "antenna.radiowaves.left.and.right") { StatusView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        // Foreground job loop: poll every 30 s while the app is active.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await AppStatus.shared.refreshPermissions()
            while !Task.isCancelled {
                await BridgeRuntime.shared.jobLoop.pollOnce(trigger: "foreground")
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
