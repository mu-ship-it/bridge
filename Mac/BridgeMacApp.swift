import Observation
import SwiftUI
import WidgetKit

/// 白手套 Mac: a menu-bar host for the Board · 看板 desktop widget. It holds the box URL, token and
/// device id in the Keychain (shared with the widget), and while it runs checks the boards on
/// screen every 30 s, reloading the widget only when what it shows would change.
@main
enum BridgeMacMain {
    static func main() {
        if let code = HostCommandLine.run(CommandLine.arguments, stdin: HostCommandLine.readStdin) {
            exit(code)
        }
        BridgeMacApp.main()
    }
}

struct BridgeMacApp: App {
    @State private var host = HostState.shared

    var body: some Scene {
        MenuBarExtra {
            HostMenu(host: host)
        } label: {
            Text("手")
        }
        Settings {
            HostSettings()
        }
    }
}

@MainActor @Observable
final class HostState {
    static let shared = HostState()

    var lastCheck: Date?
    var lastReload: Date?
    var boards: [String] = []

    private var task: Task<Void, Never>?

    private init() {
        start()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: BoardWatcher.interval)
            }
        }
    }

    func check() async {
        let names = await BoardWidgetKind.configuredNames()
        let reloaded = await BoardWatcher(names: { names }).check()
        boards = names
        lastCheck = Date()
        if reloaded { lastReload = lastCheck }
    }

    func reloadNow() {
        WidgetCenter.shared.reloadTimelines(ofKind: BoardWidgetKind.kind)
        lastReload = Date()
    }
}

private struct HostMenu: View {
    let host: HostState

    var body: some View {
        Text(host.boards.isEmpty ? "No board widget on the desktop" : "Watching: \(host.boards.joined(separator: ", "))")
        if let check = host.lastCheck {
            Text("Checked \(check.formatted(date: .omitted, time: .standard))")
        }
        if let reload = host.lastReload {
            Text("Reloaded \(reload.formatted(date: .omitted, time: .standard))")
        }
        Divider()
        Button("Reload widgets") { host.reloadNow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit 白手套 Mac") { NSApplication.shared.terminate(nil) }
    }
}

private struct HostSettings: View {
    @State private var url = MacKeychain.string(.url) ?? (Bundle.main.object(forInfoDictionaryKey: "BridgeDefaultServerURL") as? String ?? "")
    @State private var device = MacKeychain.string(.device) ?? "mac"
    @State private var token = ""
    @State private var hasToken = MacKeychain.string(.token) != nil
    @State private var message: String?

    var body: some View {
        Form {
            TextField("Server URL", text: $url)
            TextField("Device id", text: $device)
            SecureField(hasToken ? "Token saved — type to replace" : "Token", text: $token)
            HStack {
                Button("Save") { save() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func save() {
        do {
            try MacKeychain.set(url.trimmingCharacters(in: .whitespaces), for: .url)
            try MacKeychain.set(device.trimmingCharacters(in: .whitespaces), for: .device)
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { try MacKeychain.set(t, for: .token) }
            token = ""
            hasToken = MacKeychain.string(.token) != nil
            message = "Saved"
            HostState.shared.reloadNow()
        } catch {
            message = error.localizedDescription
        }
    }
}
