"""Test fixtures.

HARD RULE (house rule "DB-IN-TREE", and the 09-15 wipe that caused it): tests never touch the
live database. Every test runs against a throwaway file under the system temp dir, and the
suite refuses to start if BRIDGE_DB points anywhere else.
"""
import os
import sys
import tempfile
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_DIR))


def _guard(path):
    """Abort the run unless `path` is inside the temp dir. Never a warning — a hard failure."""
    temp_root = Path(tempfile.gettempdir()).resolve()
    resolved = Path(path).expanduser().resolve()
    if temp_root not in resolved.parents:
        pytest.exit(
            f"REFUSING TO RUN: BRIDGE_DB={resolved} is not under {temp_root}. "
            "Tests must never run against the live database.", returncode=3)
    return resolved


def pytest_configure(config):
    """Refuse the whole run if the shell that launched pytest points at a real database."""
    incoming = os.environ.get("BRIDGE_DB")
    if incoming:
        _guard(incoming)


@pytest.fixture
def db_path(tmp_path, monkeypatch):
    path = tmp_path / "bridge-test.db"
    monkeypatch.setenv("BRIDGE_DB", str(path))
    monkeypatch.setenv("BRIDGE_ENV_FILE", str(tmp_path / "no-such-env"))
    import config
    config._file_env = None          # drop any cached operator env file
    _guard(config.db_path())
    yield path


@pytest.fixture
def conn(db_path):
    import db as db_module
    connection = db_module.connect()
    yield connection
    connection.close()


@pytest.fixture
def account(conn):
    import db as db_module
    with conn:
        account_id, token = db_module.create_account(conn, "tenant-a")
    return {"id": account_id, "token": token, "label": "tenant-a"}


@pytest.fixture
def other_account(conn):
    import db as db_module
    with conn:
        account_id, token = db_module.create_account(conn, "tenant-b")
    return {"id": account_id, "token": token, "label": "tenant-b"}


@pytest.fixture
def client(db_path):
    from fastapi.testclient import TestClient
    import app as app_module
    with TestClient(app_module.app) as test_client:
        yield test_client


def auth(account, device="my-iphone"):
    return {"Authorization": f"Bearer {account['token']}", "X-Bridge-Device": device}
