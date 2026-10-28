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
| `files.write`, `files.read`, `files.list`, `files.export` | The app's folder, visible in the Files app as "白手套"; `files.export` writes health data there as one JSON file |
| `wifi.info`, `nfc.read`, `sensors.sample` | Current Wi-Fi network; an NFC tag you hold the phone to; accelerometer/gyro/magnetometer/barometer |
| `home.list`, `home.get`, `home.set` | HomeKit accessories already set up in Apple's Home app. Unlocking, opening or disarming asks you first |

### Foreground only, nothing hidden

白手套 is a foreground app by rule, not just because iOS requires it. The agent may use anything iOS permits, but every job carries a plain-words `note`, and the Status screen's activity feed shows each job as it runs and how it ended. The live connection (a long poll) runs only while the app is open; it stops when the app goes to the background. Capabilities that show UI, make a sound or touch hardware (camera, mic, speech, scanner, share and compose sheets, HomeKit…) refuse with `foreground_required` when the app isn't on screen, rather than finding a way around it. In the background the app does only what iOS itself schedules: silent pushes, background refresh and health sync, each of which still lands in the feed. The reason is trust. An agent that can see your health data and open your front door should never act where you can't see it, and iOS keeps the camera, mic and HomeKit behind the same line anyway. Sending, dialling and unlocking always stay one tap of yours.

### Duty mode on iPad

On an iPhone the app is on screen only while you hold it, so jobs wait for you. On an iPad with Stage Manager every window on screen counts as foreground, so a small 白手套 window parked on a plugged-in iPad that never locks is a permanent live node: the iPad becomes the duty station (值班台), the iPhone stays the sensor you carry. Same app, same rules — duty mode keeps nothing running that you can't see.

Turn on **Settings → Duty mode**. While any 白手套 window is on screen it then keeps the connection to the box open indefinitely (reconnecting with back-off if the network drops), stops the screen from locking, shows a **值班中 / On duty** banner (uptime, last job, connection, last heartbeat) at the top of Status, and sends the box a `heartbeat` event every 5 minutes (`bridge devices` shows `duty on`). When the last window leaves the screen it stops and says so (`duty off`); when a window comes back it resumes at once. If the iPad dies without saying goodbye, the box marks its duty claim stale after 10 minutes.

Setting the iPad up:
1. **Power.** Keep it plugged in. Duty mode turns the screen-lock timer off only while 白手套 is on screen, and a screen that is always on runs the battery down.
2. **Never lock.** Either Settings → Display & Brightness → **Auto-Lock → Never**, or, to pin the iPad to 白手套 entirely, **Guided Access**: Settings → Accessibility → Guided Access → On, set a passcode, set *Display Auto-Lock* to Never; then open 白手套 and triple-click the top button → Start. (Guided Access keeps one app full screen, so it replaces Stage Manager; use one or the other.)
3. **Stage Manager window.** Control Center → Stage Manager on. Open 白手套, drag its corner to make it small, and keep it in the stage next to whatever else you're doing. At about 400 pt wide the Status screen collapses to the activity feed (tap **Details** for the rest).
4. **Permissions.** Go through the Status screen's Permissions list once on the iPad itself — they are per device.
5. Give it its own device id in Settings (e.g. `my-ipad`) so the agent can address the iPad and the iPhone separately.

### Desk display

**值班台 / Desk** turns a spare iPhone parked on a desk (plugged in, 白手套 on screen all day) into a full-screen board: the room's temperature and humidity, the weather, the lanes, and an **Attention** list of what wants you. There is no clock (put a real one next to the phone); only a small date line sits in the corner. It works in portrait and landscape. Open it from **Settings → Desk → Open desk**; turn on **Start in Desk** so a relaunch lands straight on it. The small grid button in the corner goes back to the tabs.

- **Room** is read on the phone through HomeKit, every 60 s, from any accessory with a temperature or humidity sensor (a HomePod mini has both). Put the accessory's or the room's name in **Settings → Desk → Room sensor**; leave it empty to use the first one found. A reading that is not available shows `—`.
- **Weather** comes from the box (`GET /bridge/board/desk`), which asks Open-Meteo (no key) for `BRIDGE_WEATHER_LAT` / `BRIDGE_WEATHER_LON` (default Shenyang 41.80, 123.43) and caches it for 15 minutes.
- **Attention** lists `agent.say`, `alert` and `notify` events from the last 24 h, plus any board row that is `over` or `stalled`. When a new item arrives the phone gives a haptic tap and highlights the item. It never plays sound unless the item has `"speak": true` in its payload. Tap the check box to clear an item: the phone posts an `attention.ack` event and the item leaves the list everywhere.
- **Attention takes only the room it needs.** With nothing to show it is one thin line at the bottom ("Nothing needs you"); with items it grows to fit, up to 45 % of the screen height, and Room, Weather and Lanes shrink to make space.
- **Burn-in guard.** Every 3 minutes the whole layout moves to a new spot, random within ±6 pt in x and y, over 1 s. Borders stay at the faint 1 px #2a2a2a.
- **Brightness follows you.** Something on your computer posts `POST /bridge/presence {"source": "pc", "active": true, "idle_s": 4}` every 30 s. While you are at the desk the screen is at 85 % (50 % between 23:00 and 07:00). When you are away, or no report has arrived for 90 s, it drops to 10 % (never off). A new attention item lights it for 30 s. Leaving the desk puts your own brightness back.
- While the desk shows, it counts as duty: the screen does not lock, the box gets heartbeats, and jobs (`home.set`, `agent.say`, …) keep running through the same foreground connection. Nothing runs in the background.

Setting the iPhone up (once):
1. **Power.** Keep it plugged in.
2. **Never lock.** Settings → Display & Brightness → **Auto-Lock → Never**. To pin the phone to 白手套, use **Guided Access** instead: Settings → Accessibility → Guided Access → On, set a passcode and set *Display Auto-Lock* to Never; then open 白手套 and triple-click the side button → Start.
3. **Quiet.** Turn on a Focus or **Do Not Disturb** (Control Center) so other apps' banners and sounds stay off the desk.
4. **Home.** Settings → *your name* → Home (or the Home app): the phone's Apple Account must be a member of the home that has the sensor and the power strip. Then, on Status → Permissions, allow Home on this phone.
5. Give it its own device id in Settings (e.g. `desk-mini`). Point it at the box, then turn on **Start in Desk**.

### Widgets

So you can see what the agent is doing without opening the app, 白手套 has a home-screen widget (small: the agent's last `agent.say` line, or the newest job's note, with a status square and how long ago; medium: the last three jobs, note · status · time) and lock-screen widgets (rectangular and inline: the newest job's note). The app writes a small snapshot (last 5 feed rows, the agent's line, last poll, last health sync) to its App Group after every job and sync and asks WidgetKit to redraw. Every 15 minutes the widget also asks the box itself (`GET /bridge/feed`, 5 s timeout), reading the token through a shared Keychain access group, so it shows jobs the phone has not picked up yet. Widgets show one-line summaries only, never a whole result, but they do sit on the lock screen: leave the lock-screen ones off if notes or summaries are private. Tapping a widget opens the Status tab.

The widgets follow the "Boring Box" look: black, white, 1px lines, one red. Status squares are white for done, red for running or failed, and dark grey once nothing has moved for an hour. The widgets stay black in light mode too.

**Suggest · 推荐** (medium) shows four things to open now: a calendar event in the next two hours, a retry of a job that just failed, a running lane, an app you usually open at this hour, or apps from your catalog. The box chooses them by rule (`GET /bridge/suggest`, see [docs/API.md](docs/API.md)); nothing is guessed by a model. Tapping a slot opens 白手套, which logs the tap to the box and then opens the app or URL, runs the capability, or runs the shortcut. The app catalog lives on the box in `~/.config/bridge/suggest.json`. Copy `server/suggest.example.json` there and edit it. The phone can only check for apps whose schemes are listed in `LSApplicationQueriesSchemes` (`project.yml`), so add a new app's scheme there too.

### Board widget

**Board · 看板** (medium, large, extra large on iPad, and lock-screen rectangular) shows a *board*: a list of labelled bars that something else keeps up to date. Anything that can make an HTTPS request can drive it — an agent, a cron job, a CI step. It posts a small JSON document to the box, and the widget draws it:

```bash
curl -X POST -H "Authorization: Bearer $BRIDGE_TOKEN" -H "Content-Type: application/json" \
  https://your-box.example/bridge/board/lanes -d '{
  "title": "Lanes", "updated_at": "2026-10-23T02:40:00Z",
  "sections": [{"title": "Running", "rows": [
    {"label": "build", "detail": "nightly", "color": "#00d7ff", "bar": 0.4, "bar_faded": 0.7,
     "value": "12m / 30m", "state": "ok", "url": "https://ci.example/runs/42"}]}]}'
```

- Each row: a colour stripe, one bar (solid fill = `bar`, a faded layer behind it = `bar_faded`, both 0..1), and `value` on the right. `state` is `ok`, `over` (red, full bar), `stalled` or `idle` (grey). Every field except `label` is optional. The shape and limits (64 KB, 16 sections, 64 rows each) are in [docs/API.md](docs/API.md).
- The widget asks the box (`GET /bridge/board/<name>`) every 5 minutes with the shared Keychain token. While 白手套 is on screen it checks every 30 s and redraws the widget only when the board changed. Past 180 s without a new post from your side the widget shows a red **STALE** badge — your poster stopped, or the box is unreachable.
- Long-press the widget › Edit Widget to pick the board by name (default `muster`). Tapping a row (medium and larger) opens its `url` through 白手套.
- Rows are cut to fit (medium 3, large 9 lines, extra large two columns); `+N` in the header counts the rest.

**On a Mac desktop.** The `BridgeMac` scheme builds 白手套 Mac, a menu-bar app (no Dock icon) with the same board widget for the macOS desktop. It needs a signing team: put `DEVELOPMENT_TEAM` in your `Config/Local.xcconfig` (a free Personal Team works), because the app and its widget share the token through a Keychain access group, which ad-hoc signing cannot carry. Set it up without typing into a window:

```bash
xcodebuild -scheme BridgeMac -configuration Release -allowProvisioningUpdates build
APP="$HOME/Applications/白手套 Mac.app"   # copy the built BridgeMac.app here
"$APP/Contents/MacOS/BridgeMac" --set-url https://your-box.example --set-device mac
your-secret-tool read bridge-token | "$APP/Contents/MacOS/BridgeMac" --set-token   # reads stdin, never echoes
"$APP/Contents/MacOS/BridgeMac" --login-item on
"$APP/Contents/MacOS/BridgeMac" --status
```

Then right-click the desktop › Edit Widgets… › 白手套.

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
The version is set in `project.yml` (`MARKETING_VERSION`, now 0.5). The build number is the git commit count, stamped into the built app and widget at build time, so a build from a shallow clone shows a low number.

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
3. In the Apple Developer portal, enable **HealthKit**, **Push Notifications**, **HomeKit**, **Access Wi-Fi Information**, **NFC Tag Reading** and **App Groups** (`group.<your bundle id>`, shared with the widget extension `<your bundle id>.widget`) for your App ID. Automatic signing usually does this for you, but NFC needs a paid developer account. The entitlements are already in `Bridge/Bridge.entitlements`. Background modes come from `Info.plist` and need no portal setup.
4. For silent pushes, create an **APNs auth key (.p8)** and give it to your server (never commit it). Your server sends `apns-push-type: background` with your bundle id as `apns-topic`.
5. On the phone:
   - Open Bridge → **Status** → **Permissions**, and tap **Ask** next to each permission you want to give. Each row says what it is for.
   - Ask for Location twice. The second tap upgrades the permission to *Always*, which the background keep-alive needs.
   - Make sure Background App Refresh is on.

## Point it at your own server

1. Implement the endpoints in [docs/API.md](docs/API.md) on your server:
   - Job loop: `GET /bridge/ping`, `POST /bridge/devices`, `GET /bridge/jobs`, `POST /bridge/results`
   - Device events (duty heartbeat, speech): `POST /bridge/events` (and `GET` for the agent)
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
Bridge/UI/                  Status and Settings screens, duty banner
BridgeWidget/               WidgetKit extension: home-screen and lock-screen widgets
Mac/, MacWidget/            白手套 Mac: menu-bar host + the board widget for the macOS desktop
Shared/                     Code in both the app and the widgets: snapshots, the board, App Group, shared Keychain
BridgeTests/                Unit tests (Swift Testing)
BridgeUITests/              WidgetShots scheme: puts widgets on a simulator home screen for screenshots
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
