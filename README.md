# Bridge

**Bridge is an agent-agnostic bridge to your iPhone.** It runs on the phone and exposes native iOS capabilities to a server you control, so anything running there can ask the phone a question and get a structured answer back. That could be Claude, Codex, a Hermes agent, a cron job or a ten-line shell script. It can read health data, location, calendar, reminders, contacts and recent photos. It can take a photo, scan a code, record and transcribe a voice clip, speak, open apps and Settings pages, run Shortcuts, fill in an SMS, email or call for you to confirm, work with files, read NFC tags, sample sensors and control HomeKit accessories. More can be added ([docs/CAPABILITIES.md](docs/CAPABILITIES.md)).

白手套 ("white glove") is the display name of the author's own build.

It is **not a health exporter**. Health sync is one capability among several. The core is a small job protocol ([docs/API.md](docs/API.md)): the server queues a job, the phone runs it with a native API, and the result goes back as JSON. Any server that speaks that protocol works. There's no SDK, no agent framework and no MCP requirement, though you can wrap your server in MCP if you want.

There is no cloud service and no account. The app talks to exactly one URL, the one you enter in Settings.

## How it works

The app has two base behaviours:

1. **Job loop.** The app polls `GET /bridge/jobs` on your server, runs each job with a *capability*, and posts results to `POST /bridge/results`. A poll is triggered by:
   - a long poll while the app is open (`wait=25`, re-issued at once; stops when backgrounded)
   - a silent push from your server
   - iOS background refresh and processing tasks
   - significant location changes (used only as a keep-alive)
2. **Health sync.** In the background, the app pushes HealthKit samples added since the last successful sync to `POST /hk/ingest`. It uses the same JSON shape as the [Health Auto Export](https://www.healthyapps.dev/) app, so existing HAE receivers work.

Built-in capabilities:

| Capability | What it does |
|---|---|
| `health.query` | Heart rate, resting HR, HRV, respiratory rate, blood oxygen, steps, sleep stages, workouts. Raw samples or hour/day/… buckets |
| `location.now` | One-shot location fix |
| `device.info` | Battery, model, iOS version, app version, last sync time |
| `clipboard.get`, `clipboard.set` | Read or set the pasteboard text |
| `notify.show`, `agent.say` | A local notification; a line in the app's activity feed |
| `calendar.events`, `reminders.list`, `reminders.add` | Upcoming events; reminders |
| `contacts.search`, `photos.recent`, `motion.today` | Contact lookup; recent photos (downscaled); today's steps |
| `camera.capture`, `barcode.scan` | Opens the camera on screen: a photo you take, or the first code in view |
| `mic.record` | A short recording (orange dot), transcribed on the phone when the language allows |
| `speak` | Reads text aloud |
| `haptic`, `torch`, `screen.brightness` | A tap of the Taptic Engine; the flashlight; display brightness |
| `open.url`, `shortcuts.run`, `settings.open` | Opens any URL scheme or app; runs one of your Shortcuts; opens a Settings page |
| `compose.sms`, `compose.mail`, `call` | Fills in Apple's sheet or call prompt. **You** tap Send or Call |
| `share` | The share sheet, with text, a link or a file |
| `files.write`, `files.read`, `files.list` | The app's folder, visible in the Files app as "白手套" |
| `wifi.info`, `nfc.read`, `sensors.sample` | Current Wi-Fi network; an NFC tag you hold the phone to; accelerometer/gyro/magnetometer/barometer |
| `home.list`, `home.get`, `home.set` | HomeKit accessories already set up in Apple's Home app. Unlocking, opening or disarming asks you first |

### Foreground only, nothing hidden

白手套 is a foreground app by rule, not just because iOS requires it. The agent may use anything iOS permits, but every job carries a plain-words `note`, and the Status screen's activity feed shows each job as it runs and how it ended. The live connection (a long poll) runs only while the app is open; it stops when the app goes to the background. Capabilities that show UI, make a sound or touch hardware (camera, mic, speech, scanner, share and compose sheets, HomeKit…) refuse with `foreground_required` when the app isn't on screen, rather than finding a way around it. In the background the app does only what iOS itself schedules: silent pushes, background refresh and health sync, each of which still lands in the feed. The reason is trust. An agent that can see your health data and open your front door should never act where you can't see it, and iOS keeps the camera, mic and HomeKit behind the same line anyway. Sending, dialling and unlocking always stay one tap of yours.

### Shortcuts and system settings

iOS gives apps no API for Wi-Fi, Bluetooth, Focus, Low Power, appearance or volume, but Shortcuts can change all of them. [`shortcuts/`](shortcuts/README.md) holds a recipe for each, all named "白手套 …". `server/tools/make_shortcut.py` builds them into signed `.shortcut` files that the box hosts, and adding one to the phone is a single tap ("Add Shortcut"). After that the agent calls it with `shortcuts.run`. It runs on screen in the Shortcuts app, which shows it running, so nothing changes silently.

The other direction needs no import. 白手套 ships App Intents ("Run 白手套 Capability", "Speak Text", "Open URL with 白手套", "Show 白手套 Notification", "Add to 白手套 Activity"), and they appear in the Shortcuts app on their own. A Shortcut you build can run any capability and get its JSON result back, and those runs appear in the feed too, noted "From Shortcuts".

The full wire format is in **[docs/API.md](docs/API.md)**. To add your own capability (one file plus one line), see **[docs/CAPABILITIES.md](docs/CAPABILITIES.md)**.

## Requirements

- macOS with Xcode 16 or later (Swift 6). iOS 18+ deployment target.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- To run on a real iPhone: an Apple Developer account. A paid account is needed for HealthKit background delivery and push notifications.

No third-party Swift dependencies.

## Build & test (simulator, no account needed)

```sh
git clone <this repo> && cd <repo>
xcodegen generate
xcodebuild -scheme Bridge -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Bridge -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Pick any simulator from `xcrun simctl list devices available`. Or open `Bridge.xcodeproj` in Xcode and press ⌘R.

The simulator has a Health app, so you can add sample data there. iOS background tasks never fire on the simulator. Use **Poll now** and **Sync now** on the Status screen instead. To simulate a silent push:
```sh
echo '{"aps":{"content-available":1}}' > /tmp/push.apns
xcrun simctl push booted <your bundle id> /tmp/push.apns
```

## Sign it yourself (real iPhone)

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig`. This file is gitignored. Set:
   - `BRIDGE_BUNDLE_ID`: your own reverse-DNS id, e.g. `com.yourname.bridge`
   - `DEVELOPMENT_TEAM`: your 10-character Team ID
   - `BRIDGE_DEFAULT_SERVER_URL` (optional): the URL Settings is prefilled with. The default is the author's server, `https://boringbox.dev`. Write it as `https:/$()/host`, because `//` starts a comment in xcconfig. You can also just type your URL in the app.
2. `xcodegen generate`, then open the project in Xcode and select your iPhone.
3. In the Apple Developer portal, enable **HealthKit**, **Push Notifications**, **HomeKit**, **Access Wi-Fi Information** and **NFC Tag Reading** for your App ID. Automatic signing usually does this for you, but NFC needs a paid developer account. The entitlements are already in `Bridge/Bridge.entitlements`. Background modes come from `Info.plist` and need no portal setup.
4. For silent pushes, create an **APNs auth key (.p8)** and give it to your server (never commit it). Your server sends `apns-push-type: background` with your bundle id as `apns-topic`.
5. On the phone:
   - Open Bridge → **Status** → **Permissions**, and tap **Ask** next to each permission you want to give. Each row says what it is for.
   - Ask for Location twice. The second tap upgrades the permission to *Always*, which the background keep-alive needs.
   - Make sure Background App Refresh is on.

## Point it at your own server

1. Implement the endpoints in [docs/API.md](docs/API.md) on your server:
   - Job loop: `GET /bridge/ping`, `POST /bridge/devices`, `GET /bridge/jobs`, `POST /bridge/results`
   - Health sync: `POST /hk/ingest`

   You can implement only one half. Use HTTPS; plain HTTP is allowed only for `localhost`.
   Or run the reference server in [`server/`](server/README.md) — Python 3 + SQLite, multi-tenant,
   with a `bridge` CLI for queueing jobs and reading results. See its README for setup.
2. Generate a long random token on the server (`bridge account create <label>` does this for you
   if you run the reference server).
3. In the app → **Settings**, replace the prefilled `https://boringbox.dev` with your server URL, then enter the token and a device id (any name, e.g. `my-iphone`). Tap **Save**, then **Test connection**.

To try it without a server, use the stdlib mock:
```sh
python3 tools/mock_box.py --token devtoken      # http://localhost:8787
curl -s -XPOST localhost:8787/_enqueue -d '{"capability":"device.info"}'
```
In the simulator app, set the server URL to `http://localhost:8787` and the token to `devtoken`. The mock prints the results and ingest summaries it receives.

## Privacy & security

- The token, server URL and device id are stored only in the iOS Keychain (this device only, readable after first unlock so background tasks work). The token is never logged or displayed.
- Health and location data are sent only to the configured server URL, over HTTPS.
- HealthKit access is **read-only**. The app never writes health data.
- Location: one-shot fixes on request, plus significant-change monitoring as a wake-up signal. No continuous GPS.
- Camera, microphone, NFC and HomeKit work only while the app is on screen. The camera and scanner show you what they see, recording shows iOS' orange dot, and messages, mail and calls are only ever filled in for you to send.
- Anyone holding your token can read your health data through your server. Treat the token like a password.

## Project layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated from this)
Config/                     Bridge.xcconfig (defaults) + your gitignored Local.xcconfig
Bridge/App/                 App entry, AppDelegate (push), background tasks, runtime wiring, App Intents
Bridge/Core/                Models, Capability protocol + dispatcher, BoxClient (network), Keychain, job loop, status
Bridge/Capabilities/        One file per capability + CapabilityRegistry.swift
Bridge/Health/              HealthKit queries, anchored sync, HAE JSON mapping
Bridge/Location/            One-shot + significant-change location
Bridge/Home/                HomeKit (HomeStore: the one HMHomeManager)
Bridge/UI/                  Status and Settings screens
BridgeTests/                Unit tests (Swift Testing)
docs/                       API contract, capability guide
tools/mock_box.py           Local mock server
server/                     Reference server (Python 3 + FastAPI + SQLite) — see server/README.md
server/tools/mock_phone.py  Fake iPhone, for testing a server without one
server/tools/make_shortcut.py  Builds (and signs) .shortcut files from JSON specs
shortcuts/recipes/          System-settings recipes: Focus, Wi-Fi, Bluetooth, Low Power, appearance, brightness, volume, flashlight
```

## Related projects

Other projects connect AI agents and iPhones in different ways. Here is how Bridge differs:

| Project | What it does | How Bridge differs |
|---|---|---|
| [apple-health-ai-bridge](https://github.com/roian6/apple-health-ai-bridge) | An iPhone companion syncs HealthKit to a receiver you run (SQLite), and a read-only MCP server exposes it to a local agent. | It covers health only and is tied to MCP. Bridge is a general job protocol: health is one capability next to location, device state and whatever you add, and it works with any server and any agent. |
| [health-export-mcp](https://mcpservers.org/servers/philipad/health-export-mcp) | An MCP server that reads the files written by the Health Export AI iOS app, e.g. from iCloud Drive. | That flow is a file-based health export read after the fact. Bridge answers live, on-demand queries from your server and can also do things beyond health. |
| [Hermes-iOS](https://github.com/dylan-buck/Hermes-iOS) | A self-hosted iPhone companion app (chat, voice, push) for a Hermes agent runtime. | It is a front end for one agent, where the phone is where you *talk to* the agent. In Bridge the phone is a set of *capabilities the agent calls*, with no chat UI and no tie to any agent framework. The two can be used together. |
| [iphone-use](https://mcpservers.org/servers/leeguooooo/iphone-use) | Lets an agent see and operate the iPhone's screen through an XCTest runner, from a Mac over USB. | It works through the UI and needs a Mac and a cable. Bridge uses native APIs (HealthKit, CoreLocation, …), runs in the background over the network with no Mac involved, and returns structured data instead of screens. Use iphone-use for apps that have no API, and Bridge for data the OS exposes. |

## Status

v0.3: a live foreground connection, on-screen capabilities, HomeKit and Shortcuts. Planned: a watchOS companion with a complication, a Live Activity, and more capabilities.

## License

MIT. See [LICENSE](LICENSE).
