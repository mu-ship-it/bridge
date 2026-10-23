"""POST/GET /bridge/board/{name}: the generic board the board widgets render."""
import pytest

import app as app_module
import db as store
from conftest import auth


def board(**overrides):
    body = {
        "title": "Lanes board", "updated_at": "2026-10-23T04:40:00+02:00",
        "sections": [
            {"title": "Lanes", "rows": [
                {"label": "cyan", "detail": "Mini · building widgets", "color": "#00d7ff", "bar": 0.25,
                 "bar_faded": None, "value": "24m / 98m", "state": "ok", "url": "https://example.com/a"},
                {"label": "red", "bar": 1.4, "state": "over"},
            ]},
            {"title": "Usage", "rows": [{"label": "MAX", "color": "#888", "bar": 0.31, "bar_faded": 0.12,
                                         "value": "31%", "extra": "dropped"}]},
        ],
    }
    body.update(overrides)
    return body


def bearer(account):
    return {"Authorization": f"Bearer {account['token']}"}


def test_post_then_get_returns_the_board_and_its_age(client, account):
    posted = client.post("/bridge/board/muster", headers=bearer(account), json=board())
    assert posted.status_code == 200
    assert posted.json() == {"ok": True, "name": "muster", "rows": 3}

    got = client.get("/bridge/board/muster", headers=auth(account, "my-ipad"))
    assert got.status_code == 200
    body = got.json()
    assert 0 <= body["age_s"] < 5
    assert body["board"]["title"] == "Lanes board"
    assert body["board"]["updated_at"] == "2026-10-23T02:40:00Z"       # normalised to UTC
    lanes, usage = body["board"]["sections"]
    assert lanes["rows"][0]["url"] == "https://example.com/a" and lanes["rows"][1]["bar"] == 1.4
    assert lanes["rows"][1]["detail"] is None                           # every optional field present
    assert "extra" not in usage["rows"][0]                              # unknown fields dropped


def test_a_later_post_replaces_the_board(client, account):
    client.post("/bridge/board/muster", headers=bearer(account), json=board(title="one"))
    client.post("/bridge/board/muster", headers=bearer(account), json=board(title="two"))
    assert client.get("/bridge/board/muster", headers=bearer(account)).json()["board"]["title"] == "two"


def test_age_counts_from_when_the_server_received_it(client, conn, account):
    with conn:
        store.put_board(conn, account["id"], "muster", board(), received="2020-01-01T00:00:00Z")
    assert client.get("/bridge/board/muster", headers=bearer(account)).json()["age_s"] > 180


def test_missing_board_is_404(client, account):
    response = client.get("/bridge/board/nothing", headers=bearer(account))
    assert response.status_code == 404 and response.json() == {"error": "no such board"}


def test_boards_are_scoped_by_account(client, account, other_account):
    client.post("/bridge/board/muster", headers=bearer(account), json=board())
    assert client.get("/bridge/board/muster", headers=bearer(other_account)).status_code == 404


def test_token_is_required(client, account):
    assert client.post("/bridge/board/muster", json=board()).status_code == 401
    assert client.get("/bridge/board/muster").status_code == 401
    assert client.get("/bridge/board/muster", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_bad_name_is_400(client, account):
    for name in ("Muster", "-x", "a" * 33, "a.b"):
        assert client.get(f"/bridge/board/{name}", headers=bearer(account)).status_code == 400
        assert client.post(f"/bridge/board/{name}", headers=bearer(account), json=board()).status_code == 400


@pytest.mark.parametrize("bad", [
    {"sections": "x"},
    {},
    {"sections": [{"title": "no rows"}]},
    {"sections": [{"rows": [{"detail": "no label"}]}]},
    {"sections": [{"rows": [{"label": ""}]}]},
    {"sections": [{"rows": [{"label": "a", "color": "red"}]}]},
    {"sections": [{"rows": [{"label": "a", "bar": -0.1}]}]},
    {"sections": [{"rows": [{"label": "a", "bar": "0.5"}]}]},
    {"sections": [{"rows": [{"label": "a", "bar": True}]}]},
    {"sections": [{"rows": [{"label": "a", "state": "on fire"}]}]},
    {"sections": [{"rows": [{"label": "a", "url": 5}]}]},
    {"sections": [{"rows": [{"label": "a" * 201}]}]},
    {"sections": [], "updated_at": "2026-10-23T02:40:00"},
    {"sections": [{"rows": []}] * 17},
    {"sections": [{"rows": [{"label": "a"}] * 65}]},
])
def test_bad_shape_is_400_and_nothing_is_stored(client, account, bad):
    response = client.post("/bridge/board/muster", headers=bearer(account), json=bad)
    assert response.status_code == 400 and response.json()["error"]
    assert client.get("/bridge/board/muster", headers=bearer(account)).status_code == 404


def test_non_json_body_is_400(client, account):
    for raw in (b"not json", b"[1, 2]"):
        response = client.post("/bridge/board/muster", headers={**bearer(account), "Content-Type": "application/json"},
                               content=raw)
        assert response.status_code == 400


def test_body_over_64kb_is_413(client, account):
    big = board(sections=[{"title": "x" * 100, "rows": [{"label": "a", "detail": "d" * 199}] * 64}] * 8)
    response = client.post("/bridge/board/muster", headers=bearer(account), json=big)
    assert response.status_code == 413
    assert client.get("/bridge/board/muster", headers=bearer(account)).status_code == 404


def test_minimal_board_is_fine(client, account):
    assert client.post("/bridge/board/m", headers=bearer(account), json={"sections": []}).status_code == 200
    assert client.get("/bridge/board/m", headers=bearer(account)).json()["board"] == {
        "title": None, "updated_at": None, "sections": []}


def test_every_call_is_audited_without_the_body(client, conn, account):
    client.post("/bridge/board/muster", headers=bearer(account), json=board())
    client.post("/bridge/board/muster", headers=bearer(account), json={"sections": "x"})
    client.get("/bridge/board/muster", headers=auth(account, "my-ipad"))
    client.get("/bridge/board/gone", headers=bearer(account))
    rows = [(r["endpoint"], r["device_id"], r["outcome"]) for r in store.audit_tail(conn, account["id"])]
    assert ("POST /bridge/board", None, "stored:muster:3") in rows
    assert ("POST /bridge/board", None, "bad_request:board") in rows
    assert ("GET /bridge/board", "my-ipad", "read:muster") in rows
    assert ("GET /bridge/board", None, "missing:gone") in rows
    assert not any("cyan" in str(row) for row in rows)


def test_tests_run_on_a_temp_db(db_path):
    import tempfile
    from pathlib import Path
    assert Path(tempfile.gettempdir()).resolve() in Path(db_path).resolve().parents
    assert app_module.config.db_path().resolve() == Path(db_path).resolve()
