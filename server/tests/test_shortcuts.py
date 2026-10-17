"""The shortcut generator (tools/make_shortcut.py) and the box route that hosts its output."""
import json
import plistlib
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent.parent / "tools"
RECIPES = Path(__file__).resolve().parents[2] / "shortcuts" / "recipes"
sys.path.insert(0, str(TOOLS))

import make_shortcut as ms  # noqa: E402


def spec(**overrides):
    base = {"name": "白手套 Wi-Fi on", "actions": [{"id": "is.workflow.actions.wifi.set", "params": {"OnValue": True}}]}
    base.update(overrides)
    return base


def test_every_recipe_builds_a_valid_named_shortcut():
    recipes = sorted(RECIPES.glob("*.json"))
    assert len(recipes) >= 14
    for path in recipes:
        recipe = json.loads(path.read_text())
        workflow = plistlib.loads(ms.build(recipe))
        assert workflow["WFWorkflowName"] == recipe["name"] and recipe["name"].startswith("白手套 ")
        assert [a["WFWorkflowActionIdentifier"] for a in workflow["WFWorkflowActions"]] == [a["id"] for a in recipe["actions"]]
        assert ms.SLUG.match(path.stem), path.name


def test_the_system_settings_named_in_the_task_are_all_there():
    names = {json.loads(p.read_text())["name"] for p in RECIPES.glob("*.json")}
    for want in ["Focus on", "Focus off", "Wi-Fi on", "Wi-Fi off", "Bluetooth on", "Bluetooth off",
                 "Low Power on", "Low Power off", "dark mode", "light mode", "brightness", "volume",
                 "flashlight on", "flashlight off"]:
        assert "白手套 " + want in names


def test_build_is_deterministic():
    assert ms.build(spec()) == ms.build(spec())


def test_input_and_output_placeholders_wire_actions_together():
    workflow = plistlib.loads(ms.build(json.loads((RECIPES / "brightness.json").read_text())))
    first, second = workflow["WFWorkflowActions"]
    assert workflow["WFWorkflowHasShortcutInputVariables"] is True
    assert first["WFWorkflowActionParameters"]["WFInput"]["Value"] == {"Type": "ExtensionInput"}
    ref = second["WFWorkflowActionParameters"]["WFBrightness"]["Value"]
    assert ref["Type"] == "ActionOutput" and ref["OutputUUID"] == first["WFWorkflowActionParameters"]["UUID"]


@pytest.mark.parametrize("bad", [
    spec(name="Wi-Fi on"),                                                           # no 白手套 prefix
    spec(actions=[]),
    spec(actions=[{"id": "wifi.set"}]),
    spec(actions=[{"id": "is.workflow.actions.wifi.set", "params": [1]}]),
    spec(actions=[{"id": "is.workflow.actions.wifi.set", "params": {"OnValue": {"$input": True}}}]),   # input not declared
    spec(actions=[{"id": "is.workflow.actions.wifi.set", "params": {"OnValue": {"$output": "x"}}}]),   # no previous action
    spec(color="chartreuse"),
])
def test_bad_specs_are_refused(bad):
    with pytest.raises(ms.SpecError):
        ms.build(bad)


def test_import_url_is_fully_encoded():
    url = ms.import_url("https://box.example.com/", "wifi-on", "白手套 Wi-Fi on")
    assert url == ("shortcuts://import-shortcut?url=https%3A%2F%2Fbox.example.com%2Fbridge%2Fshortcuts%2Fwifi-on.shortcut"
                   "&name=%E7%99%BD%E6%89%8B%E5%A5%97%20Wi-Fi%20on")


def test_cli_builds_unsigned_files_and_rejects_bad_slugs(tmp_path):
    good = tmp_path / "wifi-on.json"
    good.write_text(json.dumps(spec()))
    assert ms.main([str(good), "-o", str(tmp_path / "out")]) == 0
    assert (tmp_path / "out" / "wifi-on.unsigned.shortcut").is_file()
    bad = tmp_path / "Wifi On.json"
    bad.write_text(json.dumps(spec()))
    assert ms.main([str(bad), "-o", str(tmp_path / "out")]) == 1


def test_the_box_serves_signed_shortcuts_only(client, tmp_path, monkeypatch):
    monkeypatch.setenv("BRIDGE_SHORTCUTS_DIR", str(tmp_path))
    (tmp_path / "wifi-on.shortcut").write_bytes(b"AEA1signed")
    (tmp_path / "wifi-on.unsigned.shortcut").write_bytes(b"bplist00")
    response = client.get("/bridge/shortcuts/wifi-on.shortcut")
    assert response.status_code == 200 and response.content == b"AEA1signed"
    for name in ("wifi-on.unsigned.shortcut", "missing.shortcut", "..%2Fbridge.db", "wifi-on.json"):
        assert client.get(f"/bridge/shortcuts/{name}").status_code == 404, name
