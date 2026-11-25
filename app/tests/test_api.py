import pytest
from sqlalchemy.exc import OperationalError

from snipr import db, main


def create(client, url="https://example.com/page"):
    response = client.post("/api/links", json={"url": url})
    assert response.status_code == 201
    return response.json()


def test_create_link(client):
    body = create(client)
    assert len(body["code"]) == 8
    assert body["short_url"] == f"http://short.test/{body['code']}"


@pytest.mark.parametrize("url", ["not a url", "", "http://", None])
def test_rejects_malformed_url(client, url):
    assert client.post("/api/links", json={"url": url}).status_code == 422


@pytest.mark.parametrize(
    "url", ["ftp://example.com", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x"]
)
def test_rejects_unsupported_scheme(client, url):
    assert client.post("/api/links", json={"url": url}).status_code == 422


def test_redirects_with_307(client):
    response = client.get(f"/{create(client)['code']}")
    assert response.status_code == 307
    assert response.headers["location"] == "https://example.com/page"


def test_unknown_code_returns_404(client):
    assert client.get("/missing1").status_code == 404
    assert client.get("/api/links/missing1").status_code == 404


def test_redirect_increments_hits(client):
    code = create(client)["code"]
    for _ in range(3):
        client.get(f"/{code}")
    assert client.get(f"/api/links/{code}").json()["hits"] == 3


def test_link_stats(client):
    code = create(client)["code"]
    body = client.get(f"/api/links/{code}").json()
    assert body.pop("created_at")
    assert body == {"code": code, "url": "https://example.com/page", "hits": 0}


def test_code_collision_is_retried(client, monkeypatch):
    codes = iter(["samecode", "samecode", "nextcode"])
    monkeypatch.setattr(main, "new_code", lambda: next(codes))
    assert create(client)["code"] == "samecode"
    assert create(client, "https://example.com/other")["code"] == "nextcode"
    assert client.get("/samecode").headers["location"] == "https://example.com/page"


def test_liveness_does_not_need_database(client_without_db):
    assert client_without_db.get("/healthz").status_code == 200


def test_readiness_ok(client):
    assert client.get("/readyz").status_code == 200


def test_readiness_reports_database_failure(client_without_db):
    response = client_without_db.get("/readyz")
    assert response.status_code == 503
    assert response.json() == {"detail": "database unavailable"}


def test_create_schema_retries_until_database_is_up(monkeypatch):
    calls = []

    def flaky(_engine):
        calls.append(1)
        if len(calls) < 3:
            raise OperationalError("connect", {}, Exception("refused"))

    monkeypatch.setattr(db.Base.metadata, "create_all", flaky)
    db.create_schema(retry_seconds=0)
    assert len(calls) == 3


def redirects_total(client):
    for line in client.get("/metrics").text.splitlines():
        if line.startswith("snipr_redirects_total "):
            return float(line.split()[1])
    raise AssertionError("snipr_redirects_total not exposed")


def test_redirect_metric_counts_only_successes_and_has_no_code_label(client):
    code = create(client)["code"]
    before = redirects_total(client)
    client.get(f"/{code}")
    client.get("/missing1")
    assert redirects_total(client) == before + 1
    assert code not in client.get("/metrics").text


def test_homepage(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "snipr" in response.text
