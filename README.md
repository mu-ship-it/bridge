# Bridge

**Bridge is an agent-agnostic bridge to your iPhone.** It runs on the phone and exposes native iOS capabilities to a server you control, so anything running there can ask the phone a question and get a structured answer back. That could be Claude, Codex, a Hermes agent, a cron job or a ten-line shell script. Current capabilities are health queries, a one-shot location, device state, clipboard, local notifications, calendar, reminders, contacts, recent photos (downscaled), today's steps and `agent.say` (the agent narrates in the app's activity feed), and more can be added ([docs/CAPABILITIES.md](docs/CAPABILITIES.md)).

白手套 ("white glove") is the display name of the author's own build.

It is **not a health exporter**. Health sync is one capability among several. The core is a small job protocol ([docs/API.md](docs/API.md)): the server queues a job, the phone runs it with a native API, and the result goes back as JSON. Any server that speaks that protocol works. There's no SDK, no agent framework and no MCP requirement, though you can wrap your server in MCP if you want.

There is no cloud service and no account. The app talks to exactly one URL, the one you enter in Settings.

## How it works

The app has two base behaviours:

1. **Job loop.** The app polls `GET /bridge/jobs` on your server, runs each job with a *capability*, and posts results to `POST /bridge/results`. A poll is triggered by:
   - a 30 s timer while the app is open
   - a silent push from your server
   - iOS background refresh and processing tasks
   - significant location changes (used only as a keep-alive)
2. **Health sync.** In the background, the app pushes HealthKit samples added since the last successful sync to `POST /hk/ingest`. It uses the same JSON shape as the [Health Auto Export](https://www.healthyapps.dev/) app, so existing HAE receivers work.

Built-in capabilities:

| Capability | What it returns |
|---|---|
| `health.query` | Heart rate, resting HR, HRV, respiratory rate, blood oxygen, steps, sleep stages, workouts. Raw samples or hour/day/… buckets |
| `location.now` | One-shot location fix |
| `device.info` | Battery, model, iOS version, app version, last sync time |

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
3. In the Apple Developer portal, enable **HealthKit** and **Push Notifications** for your App ID. Automatic signing usually does this for you. The entitlements are already in `Bridge/Bridge.entitlements`. Background modes come from `Info.plist` and need no portal setup.
4. For silent pushes, create an **APNs auth key (.p8)** and give it to your server (never commit it). Your server sends `apns-push-type: background` with your bundle id as `apns-topic`.
5. On the phone:
   - Open Bridge → **Status** → **Request Health access**.
   - Tap **Request Location** twice. The second tap upgrades the permission to *Always*, which the background keep-alive needs.
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
- Anyone holding your token can read your health data through your server. Treat the token like a password.

## Project layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated from this)
Config/                     Bridge.xcconfig (defaults) + your gitignored Local.xcconfig
Bridge/App/                 App entry, AppDelegate (push), background tasks, runtime wiring
Bridge/Core/                Models, Capability protocol + dispatcher, BoxClient (network), Keychain, job loop, status
Bridge/Capabilities/        One file per capability + CapabilityRegistry.swift
Bridge/Health/              HealthKit queries, anchored sync, HAE JSON mapping
Bridge/Location/            One-shot + significant-change location
Bridge/UI/                  Status and Settings screens
BridgeTests/                Unit tests (Swift Testing)
docs/                       API contract, capability guide
tools/mock_box.py           Local mock server
server/                     Reference server (Python 3 + FastAPI + SQLite) — see server/README.md
server/tools/mock_phone.py  Fake iPhone, for testing a server without one
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

Early (v0.1). Planned: a watchOS companion with a complication, a Live Activity, and more capabilities.

## License

MIT. See [LICENSE](LICENSE).
