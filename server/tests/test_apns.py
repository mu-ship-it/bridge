"""APNs is optional. These cover the degraded paths; a real send needs an Apple key."""
import apns
import config


def test_unconfigured_is_a_logged_no_op(db_path, caplog):
    outcome = apns.push("a" * 64)
    assert outcome.sent is False and outcome.detail == "unconfigured"
    assert outcome.outcome == "push:unconfigured"


def test_a_device_with_no_token_yet_is_not_an_error(db_path, monkeypatch):
    for key, value in {"APNS_KEY_PATH": "/dev/null", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T",
                       "APNS_TOPIC": "org.example.Bridge"}.items():
        monkeypatch.setenv(key, value)
    assert config.apns_configured()
    assert apns.push(None).detail == "no_device_token"


def test_environment_picks_the_apns_host(db_path, monkeypatch):
    monkeypatch.setenv("APNS_SANDBOX", "0")
    assert apns.host_for("production") == apns.PROD_HOST
    assert apns.host_for("development") == apns.SANDBOX_HOST
    monkeypatch.setenv("APNS_SANDBOX", "1")
    assert apns.host_for("production") == apns.SANDBOX_HOST
