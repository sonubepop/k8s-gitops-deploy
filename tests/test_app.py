import pytest

from app.main import create_app


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    monkeypatch.setenv("GIT_COMMIT", "abc1234")
    monkeypatch.setenv("ENVIRONMENT", "test")
    return create_app().test_client()


def test_index_reports_release(client):
    body = client.get("/").get_json()
    assert body["version"] == "1.2.3"
    assert body["commit"] == "abc1234"
    assert body["environment"] == "test"
    assert body["pod"]


def test_health_and_readiness(client):
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").get_json() == {"status": "ready"}


def test_not_ready_returns_503():
    app = create_app()
    app.config["READY"] = False
    assert app.test_client().get("/readyz").status_code == 503


def test_metrics_count_requests(client):
    client.get("/")
    text = client.get("/metrics").get_data(as_text=True)
    assert 'http_requests_total{endpoint="/",method="GET",status="200"}' in text
    assert "http_request_duration_seconds_bucket" in text
    assert 'app_build_info{commit="abc1234",environment="test",version="1.2.3"} 1.0' in text


def test_unknown_route_is_404_and_counted(client):
    assert client.get("/nope").status_code == 404
    assert 'endpoint="unmatched"' in client.get("/metrics").get_data(as_text=True)
