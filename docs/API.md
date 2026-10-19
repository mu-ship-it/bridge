# Bridge ⇄ box API contract (v0.1)

The app is a client of **your server** (called "the box" in code and below). The server URL is whatever the user enters in Settings (prefilled with `https://boringbox.dev`, the author's server; replace it with yours); the phone only ever talks to that URL. Any server implementing this contract works.
Plain `http` is accepted only for `localhost` (mock server).

Endpoints: `/bridge/*` (job loop) and `/hk/ingest` (health sync, Health Auto Export–compatible). A server may implement only one half; the other simply reports errors in the Status screen. A reference mock lives in `tools/mock_box.py`.

## Auth

| Endpoint | Header |
|---|---|
| `/bridge/*` | `Authorization: Bearer <token>` |
| `/hk/ingest` | `Authorization: <token>` (raw, no `Bearer`; matches the existing Health Auto Export setup) |

All requests also send `X-Bridge-Device: <device id>` and `User-Agent: Bridge/<version> (<build>)`.
On a bad token the box returns `401`, and the phone shows "token rejected".

---

## `GET /bridge/ping?device=<id>`
Used by the "Test connection" button.
```json
{ "ok": true, "server_time": "2026-10-16T08:00:00+08:00" }
```

## `POST /bridge/devices`
Sent after APNs hands the phone a device token (at launch, once the box is configured). The box keeps the latest token per device, which it needs to send silent pushes.
```json
{
  "device": "my-iphone",
  "apns_token": "a1b2…64 hex chars",
  "apns_environment": "development",
  "app_version": "0.1.0 (1)",
  "capabilities": ["device.info", "health.query", "location.now"]
}
```
Response: any 2xx.

## `POST /bridge/events` (v0.4)
Things the device reports on its own, rather than in answer to a job: the duty-mode heartbeat, and (from v0.4 phase 2) each finished speech segment of `mic.listen`. Body is one event, or `{"device": "…", "events": [ … ]}` for a batch of up to 100. A batch is all or nothing: one bad event is a `400` and nothing is stored.
```json
{
  "device": "my-ipad",
  "events": [
    { "type": "heartbeat", "ts": "2026-10-17T09:00:00Z",
      "note": "On duty: 5-minute heartbeat from 白手套 on screen",
      "payload": { "duty": true, "reason": "interval", "uptime_s": 86400, "battery_level": 1, "battery_state": "full", "…": "…" } }
  ]
}
```
| Field | |
|---|---|
| `type` | required; lowercase letters, digits, `.`, `_`, `-`, at most 64 |
| `note` | required, non-empty: what this event is, in plain words — the same rule as a job's `note` |
| `ts` | when it happened, ISO-8601 with a timezone; the box stores it as UTC `…Z`. Absent = time received |
| `payload` | optional JSON object, at most 64 KB |

Response: `{"ok": true, "stored": n, "ids": ["e_…"]}`.

**`heartbeat`** (duty mode). Sent when duty starts, every 5 minutes while it runs, and once more with `"duty": false` when it stops (the window left the screen, or the switch was turned off). The payload is the `device.info` result plus `duty`, `reason` (`start` / `interval` / `stop: <why>`), `on_duty_since`, `uptime_s`, `connection`, `last_job_at`, `foreground_windows` and `heartbeat_interval_s`. The box copies `duty` and the event's `ts` (as `heartbeat_at`) onto the device record; `last_seen` is refreshed by every authenticated call from the device, this one included. A station that stops beating without saying goodbye (unplugged and flat, crashed, locked by hand) cannot report it, so the reference server shows its duty claim as **stale** after two missed beats (10 minutes).

## `GET /bridge/events?device=&type=&since=&limit=` (v0.4, for the agent)
Events of the token's account, oldest first. Every filter is optional.
- `device`: one device (also taken from `X-Bridge-Device`); absent = all devices of the account.
- `type`: e.g. `heartbeat`, `speech`.
- `since`: an event id (exclusive — pass the last id you saw) or an ISO-8601 time compared with when the box received the event.
- `limit`: default 100, max 500.
```json
{ "events": [ { "id": "e_01J…", "device": "my-ipad", "type": "speech", "ts": "2026-10-17T09:00:05Z",
                "received": "2026-10-17T09:00:06Z", "note": "…", "payload": { "text": "…" } } ],
  "next": "e_01J…" }
```
`next` is the cursor for the following call (`?since=<next>`); it is the last id returned, or your own `since` when nothing new arrived. Both calls are audited by type and count only, never by content: a speech event is what someone said out loud.

## `GET /bridge/feed?device=<id>[&limit=<n>]` (v0.4, for the widgets)
The device's most recent jobs, newest first, each with a one-line summary, plus the agent's latest line. The widget extension calls it every 15 minutes (5 s timeout) with the same bearer token; the app itself does not.
- `limit`: default 5, max 50; not a positive integer → `400`. A missing device id → `400`.
```json
{
  "jobs": [
    { "id": "j_01JB2", "capability": "agent.say", "note": "Narrating", "status": "done",
      "finished_at": "2026-10-19T08:00:02Z", "summary": "Morning — you slept 7 h" },
    { "id": "j_01JB1", "capability": "location.now", "note": null, "status": "running",
      "finished_at": null, "summary": "" }
  ],
  "agent_line": "Morning — you slept 7 h",
  "server_time": "2026-10-19T08:01:00Z"
}
```
- `note`: the job's `params.note`, or `null`.
- `status`: `queued`, `running` (leased to the phone), `done` or `failed`.
- `finished_at`: the result's `finished_at` (the box's own time if the phone sent none); `null` until the job ends.
- `summary`: plain text, one line, at most 80 characters, derived from the result — never the result itself, because widgets sit on the lock screen. `speak` / `agent.say` → the text; `device.info` → `battery 85% charging`; `health.query` → `heart_rate: 25 points`; `location.now` → `41.8000, 123.4000 ±35 m`; a result with `count` → `3 items`; any other success → `done`; a failure → the error message (or its code); unfinished → `""`.
- `agent_line`: the `text` of this device's most recent `agent.say` job, or `null`.
- Audited by count only (`listed:<n>`).

## `GET /bridge/jobs?device=<id>[&wait=<seconds>]`
```json
{
  "jobs": [
    {
      "id": "j_01JA9X",
      "capability": "health.query",
      "params": { "metric": "hrv", "from": "2026-10-15T00:00:00+08:00", "to": "2026-10-16T00:00:00+08:00", "interval": "hour" },
      "created_at": "2026-10-16T08:00:00+08:00",
      "note": "Checking how you slept before suggesting a run"
    },
    { "id": "j_01JA9Y", "capability": "location.now", "params": { "timeout": 15 } },
    { "id": "j_01JA9Z", "capability": "device.info" }
  ],
  "poll_after_seconds": 30
}
```
- Box semantics: when it returns a job, the box **leases** it (suggested lease: 120 s). A leased job is not returned again until the lease runs out or a result arrives. A job with no result after the lease is offered again. This gives at-least-once delivery, so the box ignores duplicate results for the same `job_id`.
- `note` (optional string) is the agent's one-line, plain-words reason for the job. The phone shows it in the Status screen's activity feed. The phone also accepts it as `params.note`. The reference server rebuilds each job from id/capability/created_at/params, so today `params.note` is the form that reaches the phone through it. Capabilities ignore unknown params.
- Empty queue: `{"jobs": []}`.
- `wait` (optional, seconds) makes this a **long poll**: the box holds the request until a job is queued for this device or `wait` seconds pass, then answers in the same shape (an empty `jobs` list when time ran out). The reference server checks the queue every 0.5 s and caps `wait` at 30; a value that is not a non-negative number is a `400`. Without `wait` the box answers at once, as in v0.1. A box should not lease jobs to a request whose client has already hung up.
- The phone's foreground connection: while the app is open and active it sends `wait=25` (request timeout 40 s) and re-issues the moment an answer arrives, so a queued job reaches the phone within about a second. Errors back off 2, 4, 8, 16, 32, then 60 s, and reset on the next success. Leaving the foreground cancels the in-flight request and stops the loop; the app never long-polls while hidden. Push, background refresh and the Poll-now button still make single instant polls (no `wait`).
- `poll_after_seconds` is a hint for the client. The phone uses it only when a box answers a `wait` request empty in under a second (meaning that box ignores `wait`). It then falls back to polling at that interval.

## `POST /bridge/results`
```json
{
  "device": "my-iphone",
  "results": [
    {
      "job_id": "j_01JA9X",
      "ok": true,
      "result": { "...capability-specific..." : "" },
      "started_at": "2026-10-16T00:00:01Z",
      "finished_at": "2026-10-16T00:00:02Z"
    },
    {
      "job_id": "j_01JA9Y",
      "ok": false,
      "error": { "code": "permission_missing", "message": "Location not requested yet — …" },
      "started_at": "2026-10-16T00:00:02Z",
      "finished_at": "2026-10-16T00:00:02Z"
    }
  ]
}
```
Response: any 2xx. The phone posts each result as soon as its job finishes (one element per POST in practice; the box must accept any number). If the POST fails, the phone keeps the results in memory and sends them again at the start of the next poll. A process kill loses them, and the job lease covers that case.

Error codes: `unknown_capability`, `bad_params`, `permission_missing`, `permission_denied`, `unavailable`, `foreground_required`, `timeout`, `location_failed`, `cancelled`, `not_found`, `failed`.

## Silent push (box → APNs → phone)
```json
{ "aps": { "content-available": 1 }, "bridge": "poll" }
```
- APNs headers: `apns-push-type: background`, `apns-priority: 5`, `apns-topic: <your app bundle id>`.
- The phone runs one job poll. With `"bridge": "sync"`, it also runs one health sync.
- iOS throttles background pushes (roughly a few per hour). Do not rely on them for latency. Silent pushes need the APNs key and the push entitlement (see the report).

---

## Capabilities

### `health.query`
| param | meaning |
|---|---|
| `metric` (required) | `heart_rate`/`hr`, `resting_heart_rate`/`rhr`, `heart_rate_variability`/`hrv`, `respiratory_rate`, `blood_oxygen_saturation`/`spo2`, `step_count`/`steps`, `sleep`, `workouts` |
| `from`, `to` | ISO-8601 or `yyyy-MM-dd`. Defaults to the last 24 h |
| `interval` | `raw` (default), `minute`, `hour`, `day`, `week`, `month`, `<n>m`, `<n>h`, `<n>d` (ignored for sleep and workouts) |
| `limit` | max raw samples (default 5000, cap 20000) |

Result (raw):
```json
{
  "from": "2026-10-15T00:00:00Z", "to": "2026-10-16T00:00:00Z", "interval": "raw", "count": 2,
  "metric": { "name": "heart_rate", "units": "count/min",
              "data": [ { "date": "2026-10-16 08:00:00 +0800", "qty": 72, "source": "Apple Watch" } ] }
}
```
Bucketed, discrete metrics: `data` items are `{"date","qty","Avg","Min","Max"}`, with `qty` equal to Avg. For cumulative metrics (steps), `qty` is the sum.
Sleep: `metric.name = "sleep_analysis"`, `units = "hr"`, items `{"date","startDate","endDate","value":"Core|Deep|REM|Awake|In Bed|Asleep","qty":<hours>,"source"}`.
Workouts: `metric.name = "workouts"`, items `{"id","name","start","end","duration"(s),"activeEnergyBurned":{"qty","units":"kcal"},"distance":{"qty","units":"km"},"source"}`.
SpO2 is reported as 0–100 (HealthKit stores 0–1).

### `location.now`
params: `timeout` (s, 1–60, default 20).
```json
{ "lat": 37.3349, "lon": -122.009, "horizontal_accuracy_m": 35, "altitude_m": 12.0, "speed_mps": 0, "course_deg": 90, "timestamp": "2026-10-16T00:00:00Z" }
```

### `device.info`
No params.
```json
{
  "battery_level": 0.82, "battery_state": "unplugged", "low_power_mode": false,
  "model": "iPhone", "model_identifier": "iPhone17,1", "system_name": "iOS", "system_version": "27.0",
  "app_version": "0.1.0 (1)", "last_sync": "2026-10-16T00:00:00Z", "last_poll": "2026-10-16T00:05:00Z",
  "background_refresh": "Available"
}
```


### `clipboard.get`
No params. iOS may show "Allow Paste" in the foreground; in the background the text is usually `null`.
```json
{ "text": "hello", "has_image": false, "changed_at": "2026-10-16T00:00:00Z" }
```
`changed_at` is present only when the current content was written by `clipboard.set`.

### `clipboard.set`
params: `text` (string, required). Result `{"ok": true}`.

### `notify.show`
params: `title`, `body` (at least one; max 200 / 4000 chars), `sound` (bool, default true). Shows a local notification immediately. The first call asks for notification permission (the prompt only appears while the app is open; there is also a Status button). Result `{"ok": true, "id": "bridge.<job id>"}`.

### `calendar.events`
params: `from`, `to` (ISO-8601 or `yyyy-MM-dd`; default now → +7 days; max 366 days). Max 500 events.
```json
{ "from": "…", "to": "…", "count": 1,
  "events": [ { "title": "Standup", "start": "2026-10-16T01:00:00Z", "end": "2026-10-16T01:15:00Z", "location": null, "calendar": "Work", "all_day": false } ] }
```

### `reminders.list`
params: `completed` (bool, default false → open reminders). Max 500.
```json
{ "count": 1, "reminders": [ { "id": "…", "title": "Buy tea", "due": "2026-10-17", "completed": false, "list": "Errands", "notes": "…" } ] }
```
`due` is `yyyy-MM-dd` for date-only reminders, ISO-8601 otherwise; omitted when unset.

### `reminders.add`
params: `title` (required), `due` (ISO-8601 date-time adds an alarm; `yyyy-MM-dd` = date only), `list` (list name, case-insensitive; default list if omitted, `not_found` if no match). Result: the new reminder, same shape as a `reminders.list` item.

### `contacts.search`
params: `query` (required; name, email or phone number), `limit` (1–20, default 20).
```json
{ "count": 1, "contacts": [ { "name": "Alice Example", "phones": ["+1 555 0100"], "emails": ["alice@example.com"] } ] }
```

### `photos.recent`
params: `count` (1–10, default 3), `max_px` (64–2048, default 512; longest edge). Images are always re-encoded at ≤ `max_px`; originals never leave the phone.
```json
{ "count": 1, "photos": [ { "id": "…/L0/001", "created": "2026-10-16T00:00:00Z", "lat": 41.8, "lon": 123.4, "width": 512, "height": 384, "jpeg_base64": "/9j/…" } ] }
```

### `motion.today`
No params. CMPedometer totals since local midnight. `unavailable` on devices without a pedometer (and in the simulator).
```json
{ "from": "2026-10-15T16:00:00Z", "to": "2026-10-16T02:00:00Z", "steps": 4210, "distance_m": 3120.5, "floors_up": 3, "floors_down": 2 }
```

### `agent.say`
params: `text` (required, max 2000 chars), `notify` (bool, default false). Adds `text` to the app's activity feed: the job's own row shows it. This is how the agent narrates when nothing needs running. With `notify: true` it is also shown as a local notification titled with the app's display name. Result `{"ok": true, "notified": true}`. If the notification could not be shown, `notified` is false and `notify_error` holds the code (e.g. `permission_denied`), and the job still succeeds.

### On-screen capabilities (v0.3)

白手套 is a foreground app. Nothing in this group runs hidden: each one either shows Apple's own UI (camera, scanner, share sheet, compose sheets, the NFC sheet, the call prompt), or makes itself seen or heard (sound, haptics, torch, brightness, opening another app). iOS allows all of these only while the app is on screen. When it is not, the job fails with `foreground_required` and can be retried later. Every job carries its `note` into the Status activity feed as usual.

Capabilities that wait for Mu (camera, scanner, share, compose) take `timeout` (5–110 s, default 90). If Mu hasn't answered by then, the sheet is closed and the job fails with `timeout`. The cap stays under the box's 120 s lease, so a forgotten sheet never gets the job offered twice. When Mu closes a sheet, the result is `cancelled`.

Hardware the device lacks (every camera/NFC/torch/Wi-Fi/telephony/sensor capability in the simulator) gives a plain `unavailable`.

### `camera.capture`
params: `facing` (`back` default, `front`), `max_px` (64–4096, default 1024; longest edge), `timeout`. Opens the camera on screen; Mu takes the picture.
```json
{ "jpeg_base64": "/9j/…", "width": 1024, "height": 768 }
```

### `barcode.scan`
params: `timeout`. Opens a live scanner (VisionKit) and returns the first code in view: QR, EAN/UPC, Code 128, PDF417, Aztec, Data Matrix…
```json
{ "payload": "https://example.com/ticket/42", "symbology": "qr" }
```

### `mic.record`
params: `seconds` (1–60, default 10), `transcribe` (default true), `audio` (default true; include the clip), `locale` (e.g. `zh-CN`; default the phone's language). Records from the microphone while the app is open; iOS shows its orange dot. Transcription uses Apple's speech recognizer, on the phone when the locale supports it (`on_device`). A transcription problem doesn't lose the clip: it comes back as `transcript_error`, and the job still succeeds.
```json
{ "seconds": 10, "m4a_base64": "AAAAHGZ0eXBNNEEg…", "transcript": "remind me to call the bank", "on_device": true, "locale": "en_US" }
```
Needs Microphone, plus Speech Recognition for `transcribe` (Status → Permissions → Ask).

### `speak`
params: `text` (required, ≤ 4000 chars), `rate` (0–1, default 0.5 = normal speed), `voice` (a language like `zh-CN`, or a voice identifier; default is a voice for the text's own language). Reads aloud, even with the ring switch on silent, and answers once it has finished: `{"spoken": true, "voice": "com.apple.voice.compact.zh-CN.Tingting", "seconds": 3.4}`.

### `haptic`, `torch`, `screen.brightness`
- `haptic` `{style?}`: `light`, `medium` (default), `heavy`, `soft`, `rigid`, `selection`, `success`, `warning`, `error`. Returns `{"style": "medium"}`.
- `torch` `{on, level?}`: `level` is 0.01–1 (default 1). Returns `{"on": true, "level": 1}`.
- `screen.brightness` `{level}`: `level` is 0–1. Returns `{"level": 0.8, "previous": 0.42}`. iOS may restore the old level when the phone locks.

### `open.url`
params: `url` (required; any scheme: `https:`, `maps:`, `tel:`, `weixin:`, …). iOS opens the app that owns the scheme, and 白手套 leaves the screen. Returns `{"opened": true}`; `false` means no installed app handles the scheme. The result reaches the box even though the app has just left the screen. Later jobs in the same batch wait until Mu comes back.

### `shortcuts.run`
params: `name` (required; the shortcut's exact name), `input` (optional; a string, or any JSON value sent as its JSON text). Opens `shortcuts://run-shortcut?name=…&input=text&text=…`, and the Shortcuts app runs it on screen. Returns `{"opened": true}`. **The shortcut's output does not come back to the agent through this job.** A shortcut that should report back must call the box itself, for example with a "Get Contents of URL" action.

### `settings.open`
params: `section`, one of `app` (default; 白手套's own page), `app_notifications`, `wifi`, `bluetooth`, `cellular`, `notifications`, `privacy`, `battery`, `display`, `focus`, `general`. Returns `{"opened": true, "section": "wifi"}`. `app` and `app_notifications` use Apple's public links. The system pages use Settings' `App-prefs:` links, which Apple does not document, so on some iOS versions they open the top of Settings rather than the exact page. Opening a page changes nothing; Mu makes the change.

### `compose.sms`, `compose.mail`, `call`
**iOS never lets an app send a message, send an email or place a call by itself.** These fill in Apple's own sheet, and Mu reads it and decides.
- `compose.sms` `{to, body?}`: `to` is a phone number or email (iMessage), a comma list or an array, 1–20 of them.
- `compose.mail` `{to, cc?, subject?, body?, html?}`.
- `call` `{number}`: iOS always shows its "Call …?" prompt first.

Result: `{"shown": true}`. For SMS and mail, iOS also reports which button Mu pressed, as `user_action` (`sent`, `saved` for mail, `cancelled`, `failed`). The app itself sent nothing either way. Whether a call was actually placed is never reported to apps. `unavailable` when the device cannot text, has no Mail account, or is the simulator.

### `files.write`, `files.read`, `files.list`
The app's Documents folder, which the Files app shows as **On My iPhone › 白手套**. It is flat (plain names, no folders), and each file is ≤ 10 MB.
- `files.write` `{name, text | base64, append?}` → `{"name": "notes.txt", "size": 42}`
- `files.read` `{name, as?}` → `{"name", "size", "text"}` for a UTF-8 file, or `"base64"` otherwise (or with `as: "base64"`). An unknown name is `not_found`.
- `files.list` → `{"count": 2, "files": [{"name": "a.txt", "size": 42, "modified": "2026-10-16T08:00:00Z"}]}`

### `share`
params: at least one of `text`, `url`, `file` (a name from `files.list`), plus `timeout`. Presents the share sheet, and Mu picks the destination. Returns `{"completed": true, "activity": "com.apple.UIKit.activity.Message"}`.

### `wifi.info`
No params. Returns `{"connected": true, "ssid": "Home", "bssid": "aa:bb:cc:dd:ee:ff", "signal": 0.8, "secure": true}`, or `{"connected": false}` when the phone isn't on Wi-Fi. iOS gives the network name only to apps with location access.

### `nfc.read`
params: `timeout` (5–60 s, default 30; iOS ends any NFC scan at 60 s). iOS shows its "Ready to Scan" sheet, and Mu holds the phone to a tag. Returns the first NDEF message:
```json
{ "records": [ { "tnf": 1, "type": "U", "payload_base64": "BGV4YW1wbGUuY29t", "uri": "https://example.com" } ] }
```

### `sensors.sample`
params: `seconds` (1–10, default 2), `hz` (1–50, default 10). Raw readings over that window. Each sensor is `{available, samples}`, where each sample is an array starting with `t` (seconds from the start):
`accelerometer` `[t, x, y, z]` g · `gyro` `[t, x, y, z]` rad/s · `magnetometer` `[t, x, y, z]` µT · `barometer` `[t, kPa, relative_altitude_m]` (about 1 Hz; needs Motion & Fitness, otherwise `available: false` with a `reason`).

### HomeKit: `home.list`, `home.get`, `home.set`
白手套 sees and controls the accessories **already set up in Apple's Home app**. Pairing, rooms, scenes and automations stay there. HomeKit answers only while the app is on screen (`foreground_required` otherwise). Mu grants access once with Status → Permissions → **Ask** next to Home. The simulator answers `unavailable`.

- `home.list` `{home?}`: every home → room → accessory → service → characteristic, with last-known values, plus `summary`, one plain line per accessory:
```json
{
  "homes": [ { "name": "Home", "id": "…", "primary": true, "rooms": [ { "name": "Living Room", "accessories": [
    { "name": "Lamp", "id": "6F1C…", "room": "Living Room", "reachable": true, "category": "Lightbulb",
      "services": [ { "name": "Lamp", "type": "Lightbulb", "characteristics": [
        { "name": "power", "description": "Power State", "value": true, "writable": true, "format": "bool" },
        { "name": "brightness", "description": "Brightness", "value": 60, "writable": true, "format": "int", "unit": "percent", "min": 0, "max": 100 } ] } ] } ] } ] } ],
  "summary": [ "Living Room / Lamp: power on, brightness 60", "Hallway / Front Door: lock_current 1, lock_target 1" ]
}
```
- `home.get` `{accessory, characteristic?, room?, home?}`: reads fresh values from the accessory. It returns `{"accessory", "room", "reachable", "values": {"power": true, "brightness": 60}}`, or `{"accessory", "room", "characteristic", "value"}` for one characteristic.
- `home.set` `{accessory, characteristic, value, room?, home?}`: writes one value and returns `{"accessory", "characteristic", "value"}`. The value is checked against the characteristic's format, min/max and valid values (`bad_params` names the limit). Booleans take `true`/`false` or `"on"`/`"off"`.

`accessory` is a name (case-insensitive; add `room` when two share a name) or the `id` from `home.list`. `characteristic` is a short name: `power`, `brightness`, `hue`, `saturation`, `color_temperature`, `current_temperature`, `target_temperature`, `target_heating_cooling`, `humidity`, `lock_current`, `lock_target` (0 unlock, 1 lock), `door_current`, `door_target` (0 open, 1 close), `active`, `rotation_speed`, `target_position`, `motion`, `contact`, `battery_level`, `security_target` (3 disarm), `volume`, `mute`, …. It can also be the snake_case of the Home app's own label, or the raw HomeKit type UUID. An unknown one is `not_found`, and the message lists what the accessory has.

**Unlocking a lock, opening a garage door or disarming a security system asks Mu on screen first** ("Your agent asks to unlock “Front Door” (Hallway)"). "Don't Allow" is `cancelled`; no answer within `timeout` (default 90 s) is `timeout`. Locking, closing and arming never ask. An accessory that is off or out of range is `unavailable`.

Error codes used by these capabilities: `bad_params`, `permission_missing` (never asked; tap **Ask** next to it in the Status screen's Permissions section), `permission_denied`, `unavailable`, `not_found`, `foreground_required`, `cancelled`, `timeout`.

### Called from the phone's own Shortcuts (App Intents)
Shortcuts that Mu builds can call 白手套 directly, without the box: **Run 白手套 Capability** (any capability by name, params as JSON text, returns the result as JSON text), **Speak Text**, **Open URL with 白手套**, **Show 白手套 Notification** and **Add to 白手套 Activity**. They appear in the Shortcuts app with no import. Each one opens the app, runs through the same dispatcher, and shows in the activity feed with the note "From Shortcuts". A failure carries its error code. These runs are local, so nothing is posted to the box.

---

## `POST /hk/ingest` (existing)
This is the Health Auto Export shape. The periodic sync (BG refresh about every 15 min and BG processing about every hour, both at iOS's discretion) sends only the samples **added since the last successful sync**. It keeps one HealthKit anchor per type and moves an anchor forward only after a 2xx. The first sync looks back 7 days, with a limit of 2000 samples per type per run, so a backlog drains over several runs. Nothing is sent when there is nothing new.
```json
{
  "data": {
    "metrics": [
      { "name": "heart_rate", "units": "count/min", "data": [ { "date": "2026-10-16 08:00:00 +0800", "qty": 72, "source": "Apple Watch" } ] },
      { "name": "step_count", "units": "count", "data": [ { "date": "2026-10-16 08:00:00 +0800", "qty": 120 } ] },
      { "name": "sleep_analysis", "units": "hr", "data": [ { "date": "2026-10-16 01:00:00 +0800", "startDate": "2026-10-16 01:00:00 +0800", "endDate": "2026-10-16 02:30:00 +0800", "value": "Deep", "qty": 1.5 } ] }
    ],
    "workouts": [ { "id": "UUID", "name": "Running", "start": "…", "end": "…", "duration": 1800, "activeEnergyBurned": { "qty": 301.4, "units": "kcal" }, "distance": { "qty": 5.02, "units": "km" } } ]
  }
}
```
Metric names used: `heart_rate`, `resting_heart_rate`, `heart_rate_variability`, `respiratory_rate`, `blood_oxygen_saturation`, `step_count`, `sleep_analysis`.
Note for the box: sleep goes out as **unaggregated segments** (one row per stage segment, `qty` in hours), not as HAE's nightly aggregate. The ingest parser should accept `value`/`startDate`/`endDate`.

---

## Server notes (box side)

The phone half of this document is the contract; this section is what a server implementing it
has to decide anyway, written down so two implementations agree. The reference server lives in
[`server/`](../server/README.md). Nothing here changes what the app sends.

**Which device id wins.** Every request carries `X-Bridge-Device`, and `/bridge/jobs` and
`/bridge/ping` also take `?device=`, while `/bridge/devices` and `/bridge/results` carry
`device` in the body. The reference server takes the first non-empty of query → header → body;
they are the same value in practice. A request that resolves to no device id at all is a `400`
(the one exception is `/bridge/ping`, which answers without one).

**Error bodies.** Any non-2xx carries `{"error": "<short reason>"}`. The app only reads the
status code, but a human running curl needs something. The server's own rejection is
`{"error": "unauthorized"}` — deliberately distinct, so when a reverse proxy or SSO layer in
front of the box answers first you can tell which layer said no.

**`/bridge/*` must not sit behind another auth gate.** The phone sends a Bridge bearer token and
nothing else: no cookie, no SSO redirect to follow. A site-wide gate in front of these paths
turns every call into "token rejected" in the Status screen.

**A job that is never answered.** The contract says a leased job is offered again once its lease
runs out, which on its own loops forever. The server caps it: after `max attempts` leases with
no result (3 by default) the job is marked failed with the already-documented `timeout` error
code, so a job always reaches a terminal state and `job wait` always returns.

**Unknown devices.** A device does not have to call `POST /bridge/devices` before it polls —
that call exists to hand over an APNs token. The server records a device on first authenticated
sight; registration then fills in the token, app version and capability list.

**Multi-tenancy.** A token identifies an *account*, not a device. A device id only has to be
unique within its account, and every query is scoped by account, so two tenants may both use
`my-iphone`. Revoking an account invalidates its token at once.

**Extra response fields.** `POST /bridge/results` answers `{"ok": true, "accepted": n,
"duplicate": n, "unknown": n, "invalid": n}` — the contract only requires 2xx, and the app
ignores the body; the counts are there for curl and for the smoke script. `duplicate` is the
at-least-once case the contract tells the box to swallow.

**Device record.** `bridge devices` (alias of `bridge device list`) prints per device:
`last_seen` (any authenticated call from it), `duty on(beat <ts>)` / `duty off` /
`duty stale(last beat <ts>)`, APNs yes/no, app version and capabilities. `bridge events <account>
[--device] [--type] [--since] [--limit] [--json]` reads the events table. Purging a device erases
its events too.

### `GET /bridge/shortcuts/<slug>.shortcut` (server only)
Serves a signed shortcut file from `BRIDGE_SHORTCUTS_DIR`, for `shortcuts://import-shortcut?url=…` (see [shortcuts/README.md](../shortcuts/README.md)). This route takes **no token**, because the Shortcuts app fetches the file itself. Only plain `<slug>.shortcut` names are served: no paths, no `*.unsigned.shortcut`. Anything else is a `404`.

### `GET /bridge/health` (server only)
Unauthenticated liveness, for systemd and deployment checks. Not part of the phone contract —
the app never calls it.
```json
{ "ok": true, "service": "bridge", "version": "0.1.0" }
```
