import SwiftUI

struct SettingsView: View {
    @State private var url = ConfigStore.savedURL ?? AppInfo.defaultServerURL
    @State private var deviceId = ConfigStore.savedDeviceId ?? "my-iphone"
    @State private var token = ""
    @State private var hasToken = ConfigStore.hasToken
    @State private var message: String?
    @State private var testing = false
    @Bindable private var duty = DutyStation.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://boringbox.dev", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Device id", text: $deviceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(hasToken ? "Token saved — type to replace" : "Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Any server implementing the Bridge API (docs/API.md). Stored in the Keychain on this device. Health data is only ever sent to this URL.")
                }
                Section {
                    Button("Save") { save() }
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(testing)
                }
                Section {
                    Toggle("Duty mode", isOn: $duty.enabled)
                } header: {
                    Text("值班 / Duty")
                } footer: {
                    Text("For an iPad left plugged in with 白手套 in a small Stage Manager window. While the app is on screen: the connection to the box stays open for as long as it runs, the screen does not lock, and the box gets a heartbeat every 5 minutes. When 白手套 leaves the screen it all stops, and resumes when it comes back. Nothing runs in the background.")
                }
                if let message {
                    Section("Result") { Text(message).font(.callout) }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func save() {
        do {
            try ConfigStore.save(url: url, token: token, deviceId: deviceId)
            token = ""
            hasToken = ConfigStore.hasToken
            message = hasToken ? "Saved." : "Saved — but no token yet."
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() {
        save()
        guard let config = ConfigStore.load() else {
            message = BoxError.notConfigured.localizedDescription
            return
        }
        testing = true
        Task {
            do {
                let reply = try await BoxClient(config: config).ping()
                let serverTime = reply["server_time"]?.stringValue.map { " (server time \($0))" } ?? ""
                message = "Connected to \(config.baseURL.host() ?? "box")\(serverTime)."
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
