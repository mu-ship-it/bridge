#!/usr/bin/env python3
"""Build importable Apple Shortcuts from small JSON specs (stdlib only).

    python3 tools/make_shortcut.py ../shortcuts/recipes/*.json -o ~/bridge-data/shortcuts --sign \
        --base-url https://box.example.com

A spec names the shortcut and lists its actions:

    {
      "name": "白手套 Wi-Fi on",
      "input": false,
      "actions": [ { "id": "is.workflow.actions.wifi.set", "params": { "OnValue": true } } ]
    }

Inside `params`, two placeholders wire values between actions:
  {"$input": true}        the shortcut's own input (what `shortcuts.run {input}` passes in; needs "input": true)
  {"$output": "Numbers"}  the previous action's output, by the name Shortcuts gives it

Since iOS 15 a shortcut file must be signed before an iPhone will import it. `--sign` runs
macOS' own `shortcuts sign --mode anyone` (a Mac signed in to iCloud), which writes
`<slug>.shortcut`; without it you get `<slug>.unsigned.shortcut` only. The box serves signed
files at /bridge/shortcuts/<slug>.shortcut, and the phone imports one with a single tap on
"Add Shortcut" after the agent sends `open.url` with the printed import URL.
"""
import argparse
import json
import plistlib
import re
import subprocess
import sys
import uuid
from pathlib import Path
from urllib.parse import quote

NAME_PREFIX = "白手套 "
ACTION_ID = re.compile(r"^is\.workflow\.actions\.[a-z0-9][a-z0-9.]*$")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
CLIENT_VERSION = "2607.0.2"     # the Shortcuts build that wrote the file; iOS imports newer and older alike

# Icon colours Shortcuts accepts (WFWorkflowIconStartColor), by name.
COLORS = {"red": 4282601983, "orange": 4251333119, "yellow": 4271458815, "green": 4292093695,
          "teal": 431817727, "blue": 463140863, "indigo": 946986751, "purple": 2071128575,
          "pink": 3679049983, "gray": 255}
GLYPH_DEFAULT = 59511            # the "gear" glyph


class SpecError(ValueError):
    pass


def action_uuid(name, index):
    """Stable per shortcut and position, so rebuilding a recipe gives byte-identical output."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"bridge-shortcut:{name}:{index}")).upper()


def _resolve(value, name, index, has_input):
    """Replace the $input / $output placeholders with Shortcuts' variable attachments."""
    if isinstance(value, dict) and set(value) == {"$input"}:
        if not has_input:
            raise SpecError(f"{name}: action {index} uses $input but the spec has no \"input\": true")
        return {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}
    if isinstance(value, dict) and set(value) == {"$output"}:
        if index == 0:
            raise SpecError(f"{name}: the first action has no previous output to use")
        return {"Value": {"Type": "ActionOutput", "OutputName": str(value["$output"]),
                          "OutputUUID": action_uuid(name, index - 1)},
                "WFSerializationType": "WFTextTokenAttachment"}
    if isinstance(value, dict):
        return {k: _resolve(v, name, index, has_input) for k, v in value.items()}
    if isinstance(value, list):
        return [_resolve(v, name, index, has_input) for v in value]
    return value


def validate(spec):
    if not isinstance(spec, dict):
        raise SpecError("a spec is a JSON object")
    name = spec.get("name")
    if not isinstance(name, str) or not name.startswith(NAME_PREFIX) or len(name) > 100:
        raise SpecError(f"name must start with '{NAME_PREFIX}' so shortcuts.run can find it: {name!r}")
    actions = spec.get("actions")
    if not isinstance(actions, list) or not actions:
        raise SpecError(f"{name}: actions must be a non-empty list")
    for i, action in enumerate(actions):
        if not isinstance(action, dict) or not ACTION_ID.match(str(action.get("id", ""))):
            raise SpecError(f"{name}: action {i} needs an id like is.workflow.actions.wifi.set")
        if not isinstance(action.get("params", {}), dict):
            raise SpecError(f"{name}: action {i} params must be an object")
    if spec.get("color", "blue") not in COLORS:
        raise SpecError(f"{name}: color must be one of {', '.join(COLORS)}")


def build(spec):
    """The unsigned .shortcut plist (binary) for one spec."""
    validate(spec)
    name, has_input = spec["name"], bool(spec.get("input"))
    actions = []
    for i, action in enumerate(spec["actions"]):
        params = _resolve(action.get("params", {}), name, i, has_input)
        params["UUID"] = action_uuid(name, i)
        actions.append({"WFWorkflowActionIdentifier": action["id"], "WFWorkflowActionParameters": params})
    workflow = {
        "WFWorkflowName": name,
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": CLIENT_VERSION,
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": COLORS[spec.get("color", "blue")],
                           "WFWorkflowIconGlyphNumber": int(spec.get("glyph", GLYPH_DEFAULT))},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowHasShortcutInputVariables": has_input,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFNumberContentItem"] if has_input else [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasOutputFallback": False,
    }
    return plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY, sort_keys=True)


def import_url(base_url, slug, name):
    """What the agent sends as `open.url`: Shortcuts opens with an "Add Shortcut" button."""
    file_url = f"{base_url.rstrip('/')}/bridge/shortcuts/{slug}.shortcut"
    return f"shortcuts://import-shortcut?url={quote(file_url, safe='')}&name={quote(name, safe='')}"


def sign(unsigned, signed):
    """macOS only. `--mode anyone` makes a file any iPhone can import, not just this Apple ID's."""
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned), "--output", str(signed)],
                   check=True, capture_output=True, text=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("specs", nargs="+", type=Path, help="spec files; the file name (a-z, 0-9, -) is the slug")
    ap.add_argument("-o", "--out", type=Path, default=Path("."), help="output directory")
    ap.add_argument("--sign", action="store_true", help="sign with macOS `shortcuts sign --mode anyone`")
    ap.add_argument("--base-url", help="the box's public URL, to print each import link")
    a = ap.parse_args(argv)

    a.out.mkdir(parents=True, exist_ok=True)
    failed = 0
    for path in a.specs:
        slug = path.stem
        try:
            if not SLUG.match(slug):
                raise SpecError(f"{path.name}: file name must be lowercase a-z, 0-9 and '-'")
            spec = json.loads(path.read_text())
            unsigned = a.out / f"{slug}.unsigned.shortcut"
            unsigned.write_bytes(build(spec))
            line = f"{slug}: built"
            if a.sign:
                sign(unsigned, a.out / f"{slug}.shortcut")
                line += ", signed"
            if a.base_url:
                line += f"\n  {import_url(a.base_url, slug, spec['name'])}"
            print(line)
        except (SpecError, json.JSONDecodeError) as e:
            failed += 1
            print(f"{path.name}: {e}", file=sys.stderr)
        except subprocess.CalledProcessError as e:
            failed += 1
            print(f"{path.name}: shortcuts sign failed: {(e.stderr or e.stdout or '').strip()}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
