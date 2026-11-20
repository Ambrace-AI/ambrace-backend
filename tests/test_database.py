"""DynamoDB client construction, caching and health probing (no AWS calls)."""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from botocore.exceptions import EndpointConnectionError

from app.db import database
from app.db.session_repository import RepositoryUnavailable, SessionRepository


@pytest.fixture(autouse=True)
def fresh_repository_cache():
    """Each test builds its own client; never leak a cached one between tests."""
    database.get_repository.cache_clear()
    yield
    database.get_repository.cache_clear()


def test_aws_client_uses_the_default_credential_chain(monkeypatch):
    """In AWS no endpoint is set, so no static credentials may be passed."""
    monkeypatch.setattr(database.settings, "DYNAMODB_ENDPOINT_URL", None)
    monkeypatch.setattr(database.settings, "AWS_REGION", "ap-south-1")
    monkeypatch.setattr(
        database.settings, "DYNAMODB_TABLE_NAME", "ambrace-dev-sessions"
    )

    with patch.object(database.boto3, "client") as factory:
        repository = database.get_repository()

    assert isinstance(repository, SessionRepository)
    args, kwargs = factory.call_args
    assert args == ("dynamodb",)
    assert kwargs["region_name"] == "ap-south-1"
    assert kwargs["endpoint_url"] is None
    assert kwargs["aws_access_key_id"] is None
    assert kwargs["aws_secret_access_key"] is None


def test_local_endpoint_opts_into_dummy_credentials(monkeypatch):
    """DynamoDB Local needs signed requests but must never use real credentials."""
    monkeypatch.setattr(
        database.settings, "DYNAMODB_ENDPOINT_URL", "http://localhost:8000"
    )

    with patch.object(database.boto3, "client") as factory:
        database.get_repository()

    kwargs = factory.call_args.kwargs
    assert kwargs["endpoint_url"] == "http://localhost:8000"
    assert kwargs["aws_access_key_id"] == "local"
    assert kwargs["aws_secret_access_key"] == "local"


def test_client_has_bounded_timeouts_and_retries(monkeypatch):
    """A storage outage must fail a request quickly instead of holding it open."""
    monkeypatch.setattr(database.settings, "DYNAMODB_ENDPOINT_URL", None)

    with patch.object(database.boto3, "client") as factory:
        database.get_repository()

    config = factory.call_args.kwargs["config"]
    assert config.connect_timeout == 2
    assert config.read_timeout == 3
    assert config.retries == {"mode": "standard", "total_max_attempts": 3}


def test_repository_is_built_once_and_reused():
    with patch.object(database.boto3, "client") as factory:
        first = database.get_repository()
        second = database.get_repository()

    assert first is second
    factory.assert_called_once()


def test_client_construction_failure_is_reported_as_unavailable():
    error = EndpointConnectionError(endpoint_url="https://private-endpoint")
    with patch.object(database.boto3, "client", side_effect=error):
        with pytest.raises(RepositoryUnavailable) as caught:
            database.get_repository()

    # The SDK error (which can name internal endpoints) is not chained outward.
    assert caught.value.__cause__ is None
    assert "private-endpoint" not in str(caught.value)


def test_init_db_builds_the_repository():
    with patch.object(database.boto3, "client") as factory:
        asyncio.run(database.init_db())

    factory.assert_called_once()
    assert database.get_repository.cache_info().currsize == 1


def test_close_db_closes_the_client_and_forgets_it():
    client = MagicMock()
    with patch.object(database.boto3, "client", return_value=client):
        database.get_repository()
        asyncio.run(database.close_db())

    client.close.assert_called_once()
    assert database.get_repository.cache_info().currsize == 0


def test_close_db_without_a_client_does_nothing():
    with patch.object(database.boto3, "client") as factory:
        asyncio.run(database.close_db())

    factory.assert_not_called()


@pytest.mark.parametrize(
    "probe, expected",
    [
        (AsyncMock(return_value=None), True),
        (AsyncMock(side_effect=RepositoryUnavailable("down")), False),
    ],
    ids=["reachable", "unreachable"],
)
def test_verify_connection_reports_reachability(monkeypatch, probe, expected):
    repository = MagicMock()
    repository.check_connection = probe
    monkeypatch.setattr(database, "get_repository", lambda: repository)

    assert asyncio.run(database.verify_connection()) is expected
