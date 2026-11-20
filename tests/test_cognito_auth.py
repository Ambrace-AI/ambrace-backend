"""Cognito access-token verification, exercised with locally signed tokens (no AWS calls)."""

import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.core.auth import cognito
from app.core.auth.cognito import CognitoAuthService, UnconfiguredAuthService

REGION = "ap-south-1"
POOL_ID = "ap-south-1_TestPool1"
CLIENT_ID = "test-app-client"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL_ID}"


@pytest.fixture(scope="module")
def pool_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="module")
def other_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture
def service(pool_key, monkeypatch):
    """A verifier whose JWKS lookup returns the test pool's public key."""
    svc = CognitoAuthService(REGION, POOL_ID, CLIENT_ID)
    monkeypatch.setattr(
        svc._jwks_client,
        "get_signing_key_from_jwt",
        lambda token: SimpleNamespace(key=pool_key.public_key()),
    )
    return svc


def access_token(key, **overrides):
    now = int(time.time())
    claims = {
        "sub": "user-123",
        "iss": ISSUER,
        "client_id": CLIENT_ID,
        "token_use": "access",
        "origin_jti": "session-abc",
        "iat": now,
        "exp": now + 300,
    }
    claims.update(overrides)
    claims = {name: value for name, value in claims.items() if value is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-kid"})


def test_valid_access_token_yields_the_subject(service, pool_key):
    user = service.verify_token(access_token(pool_key))
    assert user is not None
    assert user.user_id == "user-123"
    assert user.session_id == "session-abc"


@pytest.mark.parametrize(
    "overrides",
    [
        {"token_use": "id"},
        {"client_id": "another-app-client"},
        {"iss": "https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_OtherPool"},
        {"exp": int(time.time()) - 10},
        {"sub": None},
        {"sub": ""},
        {"client_id": None},
        {"token_use": None},
    ],
    ids=[
        "id-token",
        "other-client",
        "other-pool",
        "expired",
        "no-sub",
        "empty-sub",
        "no-client",
        "no-token-use",
    ],
)
def test_tokens_with_wrong_claims_are_rejected(service, pool_key, overrides):
    assert service.verify_token(access_token(pool_key, **overrides)) is None


def test_token_signed_by_another_key_is_rejected(service, other_key):
    assert service.verify_token(access_token(other_key)) is None


def test_unsigned_and_hmac_tokens_are_rejected(service):
    now = int(time.time())
    claims = {
        "sub": "user-123",
        "iss": ISSUER,
        "client_id": CLIENT_ID,
        "token_use": "access",
        "iat": now,
        "exp": now + 300,
    }
    unsigned = jwt.encode(claims, key=None, algorithm="none")
    hmac_signed = jwt.encode(
        claims, "shared-secret-shared-secret-123456", algorithm="HS256"
    )
    assert service.verify_token(unsigned) is None
    assert service.verify_token(hmac_signed) is None


def test_malformed_token_is_rejected(service):
    assert service.verify_token("not-a-jwt") is None
    assert service.verify_token("") is None


def test_jwks_failure_rejects_instead_of_raising(pool_key):
    """An unreachable or unknown key must deny access, never crash the request."""
    svc = CognitoAuthService(REGION, POOL_ID, CLIENT_ID)

    def unreachable(token):
        raise jwt.PyJWKClientError("jwks endpoint unreachable")

    svc._jwks_client.get_signing_key_from_jwt = unreachable
    assert svc.verify_token(access_token(pool_key)) is None


def test_rejections_never_log_the_token(service, pool_key, caplog):
    token = access_token(pool_key, token_use="id")
    with caplog.at_level("DEBUG"):
        assert service.verify_token(token) is None
    assert token not in caplog.text


def test_unconfigured_service_rejects_everything(pool_key):
    assert UnconfiguredAuthService().verify_token(access_token(pool_key)) is None


def test_provider_selection_follows_configuration(monkeypatch):
    cognito.get_auth_service.cache_clear()
    monkeypatch.setattr(cognito.settings, "COGNITO_USER_POOL_ID", None)
    monkeypatch.setattr(cognito.settings, "COGNITO_APP_CLIENT_ID", None)
    assert isinstance(cognito.get_auth_service(), UnconfiguredAuthService)

    cognito.get_auth_service.cache_clear()
    monkeypatch.setattr(cognito.settings, "COGNITO_USER_POOL_ID", POOL_ID)
    monkeypatch.setattr(cognito.settings, "COGNITO_APP_CLIENT_ID", CLIENT_ID)
    assert isinstance(cognito.get_auth_service(), CognitoAuthService)
    cognito.get_auth_service.cache_clear()


def test_protected_route_returns_401_when_auth_is_unconfigured(pool_key):
    """With no user pool configured the API fails closed, even for a well-formed token."""
    from app.main import app

    cognito.get_auth_service.cache_clear()
    client = TestClient(app)
    for headers in ({}, {"Authorization": f"Bearer {access_token(pool_key)}"}):
        response = client.get("/api/v1/viva/history", headers=headers)
        assert response.status_code == 401
        assert response.json()["detail"]["code"] == "AUTH_REQUIRED"
    cognito.get_auth_service.cache_clear()


@pytest.mark.parametrize(
    "pool_id, client_id",
    [(POOL_ID, None), (None, CLIENT_ID), (POOL_ID, "  ")],
)
def test_half_configured_cognito_is_a_startup_error(monkeypatch, pool_id, client_id):
    from pydantic import ValidationError

    from app.core.config import Settings

    monkeypatch.delenv("AMBRACE_SSM_PARAMETER_PREFIX", raising=False)
    with pytest.raises(ValidationError):
        Settings(
            _env_file=None,
            COGNITO_USER_POOL_ID=pool_id,
            COGNITO_APP_CLIENT_ID=client_id,
        )
