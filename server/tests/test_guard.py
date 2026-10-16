"""The guard that keeps the suite off the live database."""
import tempfile
from pathlib import Path

import pytest

from conftest import _guard


def test_a_temp_path_passes(tmp_path):
    assert _guard(tmp_path / "bridge.db")


def test_a_live_looking_path_aborts_the_run(monkeypatch):
    calls = {}

    def fake_exit(message, returncode=0):
        calls["message"] = message
        raise SystemExit(returncode)

    monkeypatch.setattr(pytest, "exit", fake_exit)
    with pytest.raises(SystemExit):
        _guard(Path.home() / "bridge-data" / "bridge.db")
    assert "REFUSING TO RUN" in calls["message"]
