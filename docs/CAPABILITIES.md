# Adding a capability

A capability is something your server can ask the phone to do. The server queues a job `{"id", "capability", "params"}`; the phone runs it and posts back `{"job_id", "ok", "result" | "error"}` (see [API.md](API.md)).

## 1. One file in `Bridge/Capabilities/`

```swift
// Bridge/Capabilities/ClipboardReadCapability.swift
import UIKit

/// Returns the current pasteboard text. No params.
struct ClipboardReadCapability: Capability {
    let name = "clipboard.read"

    func run(_ job: Job) async throws -> JSONValue {
        let text = await MainActor.run { UIPasteboard.general.string }
        guard let text else { throw CapabilityError(code: "empty", message: "Pasteboard has no text") }
        return .object(["text": .string(text)])
    }
}
```

Rules:
- **Name**: dotted, `area.verb` (`health.query`, `location.now`). This is what the server puts in `job.capability`.
- **Params**: read them from `job.params` (`[String: JSONValue]?`) and validate. On bad input, throw `CapabilityError.badParams("…")`.
- **Errors**: throw `CapabilityError(code:message:)` to send the server a stable `code`, such as `permission_missing`, `permission_denied`, `unavailable` or `timeout`. Any other error is reported as `failed`. You never build a `JobResult` yourself; `JobDispatcher` does that.
- **Concurrency**: the type must be `Sendable`, which a struct with `let`s already is. Hop to `MainActor` for UIKit, CoreLocation and similar APIs.
- **Background**: jobs can run during a silent push or a background task, where iOS allows only about 30 s. Keep `run` short and put a timeout on anything that waits.
- **Privacy**: return only what the job asked for. Data leaves the phone only through `BoxClient`, which talks to the configured server.
- If you need a new permission, add the usage string to `info.properties` in `project.yml` and add a request button to `StatusView`.

## 2. One line in `Bridge/Capabilities/CapabilityRegistry.swift`

```swift
static let all: [any Capability] = [
    HealthQueryCapability(),
    LocationNowCapability(),
    DeviceInfoCapability(),
    ClipboardReadCapability(),   // ← new
]
```

## 3. Regenerate, document, test

```sh
xcodegen generate   # new files must be added to the Xcode project
```
- Add the capability's params and result shape to `docs/API.md` under **Capabilities**.
- Put pure parsing and mapping logic in plain types and unit-test it. See `HealthQueryParams` and `BridgeTests/`.
- Try it end to end with the mock server:
  ```sh
  python3 tools/mock_box.py --token devtoken
  curl -s -XPOST localhost:8787/_enqueue -d '{"capability":"clipboard.read"}'
  ```
  The result is printed by the mock within about a second while the app is open (the foreground long poll), or tap **Poll now**.

## Built-in capabilities

| name | file | permission |
|---|---|---|
| `health.query` | `HealthQueryCapability.swift` | Health |
| `location.now` | `LocationNowCapability.swift` | Location |
| `device.info` | `DeviceInfoCapability.swift` | none |
| `clipboard.get`, `clipboard.set` | `ClipboardCapabilities.swift` | none (iOS may show "Allow Paste") |
| `notify.show` | `NotifyShowCapability.swift` | Notifications (asked on first use) |
| `calendar.events` | `EventKitCapabilities.swift` | Calendar (full access) |
| `reminders.list`, `reminders.add` | `EventKitCapabilities.swift` | Reminders (full access) |
| `contacts.search` | `ContactsSearchCapability.swift` | Contacts |
| `photos.recent` | `PhotosRecentCapability.swift` | Photos |
| `motion.today` | `MotionTodayCapability.swift` | Motion & Fitness |
| `agent.say` | `AgentSayCapability.swift` | Notifications, only with `notify: true` |

Every job shows up in the **Activity** feed on the Status screen, newest first, with time · capability · note · status (running/done/failed) and a one-line result. The feed keeps the last 200 jobs and survives a relaunch. To give a new capability a better one-line result than "ok" / "N item(s)", add a case to `ActivitySummary` in `Core/Activity.swift`.

Params for all of them are parsed by small pure types (`…Params`) using the `Params` helpers in `Core/Capability.swift`, and tested in `BridgeTests/CapabilityParamsTests.swift`. Shapes are in [API.md](API.md#capabilities).

The phone reports its capability names to the server in `POST /bridge/devices`, so a server can see what a given phone supports.
