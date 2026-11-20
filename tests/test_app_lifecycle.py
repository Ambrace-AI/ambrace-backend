"""Application startup/shutdown, the /health probe and the storage-outage response."""

from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from app import main
from app.db.session_repository import RepositoryUnavailable


def test_health_reports_connected_when_storage_answers(monkeypatch):
    monkeypatch.setattr(main, "init_db", AsyncMock())
    monkeypatch.setattr(main, "verify_connection", AsyncMock(return_value=True))

    response = TestClient(main.app).get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "healthy", "database": "connected"}


@pytest.mark.parametrize(
    "init_db, verify_connection",
    [
        (AsyncMock(), AsyncMock(return_value=False)),
        (AsyncMock(side_effect=RepositoryUnavailable("down")), AsyncMock()),
    ],
    ids=["probe-fails", "client-cannot-be-built"],
)
def test_health_returns_503_when_storage_is_down(
    monkeypatch, init_db, verify_connection
):
    """Deploy smoke tests rely on a non-200 here to catch a broken table or role."""
    monkeypatch.setattr(main, "init_db", init_db)
    monkeypatch.setattr(main, "verify_connection", verify_connection)

    response = TestClient(main.app).get("/health")

    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "unhealthy"
    assert body["database"] == "disconnected"


def test_root_stays_healthy_when_storage_is_down(monkeypatch):
    """The Lambda Web Adapter readiness check must not depend on DynamoDB."""
    monkeypatch.setattr(
        main, "init_db", AsyncMock(side_effect=RepositoryUnavailable("down"))
    )

    response = TestClient(main.app).get("/")

    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_shutdown_closes_the_database(monkeypatch):
    close_db = AsyncMock()
    monkeypatch.setattr(main, "close_db", close_db)

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200
        close_db.assert_not_awaited()

    close_db.assert_awaited_once()


def test_shutdown_surfaces_a_failed_close(monkeypatch):
    """A client that cannot be closed is a real fault; it must not be swallowed."""
    monkeypatch.setattr(
        main, "close_db", AsyncMock(side_effect=RuntimeError("close failed"))
    )

    with pytest.raises(RuntimeError, match="close failed"):
        with TestClient(main.app):
            pass


def test_storage_outage_in_a_route_returns_503_without_details(monkeypatch):
    """A repository failure anywhere becomes a retryable 503 with a safe message."""
    from app.core.auth import AuthenticatedUser, get_current_user
    from app.db.database import get_repository as real_get_repository

    def unavailable():
        raise RepositoryUnavailable("internal endpoint 10.0.0.5 timed out")

    main.app.dependency_overrides[get_current_user] = lambda: AuthenticatedUser(
        user_id="user-123"
    )
    monkeypatch.setattr(main, "init_db", AsyncMock())
    monkeypatch.setattr("app.api.deps.init_db", AsyncMock())
    monkeypatch.setattr("app.api.deps.get_repository", unavailable)
    real_get_repository.cache_clear()
    try:
        response = TestClient(main.app, raise_server_exceptions=False).get(
            "/api/v1/viva/history"
        )
    finally:
        main.app.dependency_overrides.clear()

    assert response.status_code == 503
    assert "10.0.0.5" not in response.text
    assert "temporarily unavailable" in response.json()["detail"]
