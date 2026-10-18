import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// This window's identity for ForegroundSession; each Stage Manager window has its own.
    @State private var sceneID = UUID()

    var body: some View {
        TabView {
            Tab("Status", systemImage: "antenna.radiowaves.left.and.right") { StatusView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        // Foreground connection: one long poll for the whole app while any window is on screen.
        // When the last window goes to the background the poll (and duty mode) stop at once, and
        // resume the moment a window returns. A brief .inactive does not interrupt a job.
        .onChange(of: scenePhase, initial: true) { _, phase in
            ForegroundSession.shared.update(scene: sceneID, phase: phase)
        }
        .onDisappear { ForegroundSession.shared.remove(scene: sceneID) }
    }
}
