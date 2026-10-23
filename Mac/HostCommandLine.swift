import Foundation

/// Headless setup, so nothing has to be typed into a window:
///   白手套 Mac --set-token < token-on-stdin
///   白手套 Mac --set-url https://box.example --set-device mac
///   白手套 Mac --status
/// Each run handles its flags, prints one line per flag (never the token), and exits.
enum HostCommandLine {
    /// nil = no setup flags: start the menu-bar app. Otherwise the exit code.
    static func run(_ arguments: [String], stdin: () -> String?) -> Int32? {
        let flags = ["--set-token", "--set-url", "--set-device", "--status"]
        guard arguments.contains(where: flags.contains) else { return nil }
        var args = arguments.dropFirst()[...]
        var code: Int32 = 0
        func fail(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            code = 1
        }
        while let arg = args.popFirst() {
            switch arg {
            case "--set-token":
                let token = (stdin() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { fail("--set-token: nothing on stdin"); continue }
                do { try MacKeychain.set(token, for: .token); print("token saved") } catch { fail("--set-token: \(error.localizedDescription)") }
            case "--set-url":
                guard let raw = args.popFirst(), let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? ""))
                else { fail("--set-url: needs an https URL (http only for localhost)"); continue }
                do { try MacKeychain.set(url.absoluteString, for: .url); print("url saved") } catch { fail("--set-url: \(error.localizedDescription)") }
            case "--set-device":
                guard let device = args.popFirst()?.trimmingCharacters(in: .whitespaces), !device.isEmpty
                else { fail("--set-device: needs an id"); continue }
                do { try MacKeychain.set(device, for: .device); print("device saved") } catch { fail("--set-device: \(error.localizedDescription)") }
            case "--status":
                print("url: \(MacKeychain.string(.url) ?? "not set")")
                print("device: \(MacKeychain.string(.device) ?? "not set")")
                print("token: \(MacKeychain.string(.token) == nil ? "not set" : "set")")
            default:
                break   // Launch Services and Xcode pass their own arguments (-NSDocumentRevisionsDebugMode …)
            }
        }
        return code
    }

    static func readStdin() -> String? {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }
}
