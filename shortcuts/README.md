# Shortcuts for system settings

iOS gives apps no API for Wi-Fi, Bluetooth, Focus, Low Power Mode, appearance, volume or the
flashlight's on/off state from another app, but the Shortcuts app can change every one of
them. So the agent changes them by running a shortcut (`shortcuts.run`), and this folder
holds those shortcuts as small JSON recipes. All of them are named "白手套 …" so the agent
can call them by name.

| Recipe | Shortcut name | Input |
|---|---|---|
| `focus-on.json`, `focus-off.json` | 白手套 Focus on / off | — (Do Not Disturb) |
| `wifi-on.json`, `wifi-off.json` | 白手套 Wi-Fi on / off | — |
| `bluetooth-on.json`, `bluetooth-off.json` | 白手套 Bluetooth on / off | — |
| `low-power-on.json`, `low-power-off.json` | 白手套 Low Power on / off | — |
| `dark-mode.json`, `light-mode.json` | 白手套 dark mode / light mode | — |
| `brightness.json` | 白手套 brightness | a number 0–1 (`0.6` = 60 %) |
| `volume.json` | 白手套 volume | a number 0–1 |
| `flashlight-on.json`, `flashlight-off.json` | 白手套 flashlight on / off | — |

Turning Wi-Fi off can cut the phone's only connection to the box. Make sure it has mobile data first.

## Build, sign, host (on the Mac)

Since iOS 15 an iPhone imports only **signed** shortcut files, and signing needs macOS
(`/usr/bin/shortcuts`, signed in to iCloud). Run this on the Mac, from `server/`:

```sh
python3 tools/make_shortcut.py ../shortcuts/recipes/*.json -o ~/bridge-data/shortcuts --sign \
    --base-url https://box.example.com
```

For each recipe this writes `<slug>.unsigned.shortcut` (the plist) and `<slug>.shortcut`,
signed with `shortcuts sign --mode anyone`, so any iPhone can import it. It also prints the
import link. If the box is another machine, copy the signed files into its
`BRIDGE_SHORTCUTS_DIR` (default `~/bridge-data/shortcuts`):

```sh
rsync -av ~/bridge-data/shortcuts/*.shortcut box:bridge-data/shortcuts/   # skip *.unsigned.*
```

The box serves them at `GET /bridge/shortcuts/<slug>.shortcut`. That route takes no token,
because the Shortcuts app fetches the file itself and cannot send one. It serves only plain
signed `<slug>.shortcut` names, and these files hold nothing secret.

## Adding one to the phone: one tap, once

The agent sends the printed link as an `open.url` job, with a note saying why:

```json
{ "capability": "open.url",
  "params": { "url": "shortcuts://import-shortcut?url=https%3A%2F%2Fbox.example.com%2Fbridge%2Fshortcuts%2Fwifi-on.shortcut&name=%E7%99%BD%E6%89%8B%E5%A5%97%20Wi-Fi%20on",
              "note": "Adding the Wi-Fi switch so I can turn Wi-Fi back on for you" } }
```

The Shortcuts app opens and shows the shortcut's actions with an **Add Shortcut** button. Mu
reads it and taps Add (or doesn't). That happens once per shortcut. Importing a name that already
exists may give a second copy, so remove the old one first when updating a recipe.

## Running one

```json
{ "capability": "shortcuts.run", "params": { "name": "白手套 brightness", "input": "0.6" } }
```

The phone switches to the Shortcuts app, which runs the shortcut on screen and shows its
progress, so a setting never changes out of sight. iOS then stays in Shortcuts. The
"‹ 白手套" link at the top left goes back. The job result is `{"opened": true}`, meaning the
shortcut was started. Its own output does not come back through this job.

## Writing a recipe

```json
{
  "name": "白手套 Wi-Fi on",
  "color": "blue",
  "input": false,
  "actions": [ { "id": "is.workflow.actions.wifi.set", "params": { "OnValue": true } } ]
}
```

- `name` must start with "白手套 ". The file name (lowercase a–z, 0–9, `-`) is the slug in the URL.
- `actions[].id` is Shortcuts' action identifier, and `params` are its parameters exactly as Shortcuts stores them.
- `{"$input": true}` stands for the shortcut's input (set `"input": true`). `{"$output": "Numbers"}` stands for the previous action's output, named as Shortcuts names it. See `brightness.json`.
- The build is deterministic, so the same recipe always gives the same file.

**What has been checked.** Every action identifier used here appears in macOS' own Shortcuts
frameworks, and so do the parameter keys `OnValue`, `FocusModes`, `AssertionType`,
`WFBrightness`, `WFVolume` and `WFFlashlightSetting`. The appearance keys (`operation`,
`style`) come from exported shortcuts and could not be confirmed that way. All 14 files sign
cleanly. What hasn't been tested yet is importing them on an iPhone. After adding a
shortcut, open it once in Shortcuts: if an action shows an empty field instead of the
setting, that parameter key is wrong and the recipe needs fixing.
