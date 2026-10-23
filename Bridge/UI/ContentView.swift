import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// This window's identity for ForegroundSession; each Stage Manager window has its own.
    @State private var sceneID = UUID()
    @State private var tab = "status"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Status", systemImage: "antenna.radiowaves.left.and.right", value: "status") { StatusView() }
            Tab("Settings", systemImage: "gearshape", value: "settings") { SettingsView() }
        }
        // Boring Box: always black; the tab bar stays system, white when selected.
        .preferredColorScheme(.dark)
        .tint(Theme.text)
        // A tap on a widget (`bridge-widget://status`) lands on the Status tab.
        // A tap on a Suggest slot (`bridge://suggest/<id>`): log it, then open what it points at.
        .onOpenURL { url in
            if url.scheme == "bridge-widget" { tab = "status" }
            if let id = SuggestRoute.itemID(from: url) {
                Task { await SuggestLauncher.launch(id: id) }
            }
            // A tap on a board row (`bridge://board/open?u=<url>`): open the row's URL.
            if let target = BoardRoute.target(from: url) {
                openURL(target)
            }
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
