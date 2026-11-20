"""
Amazon Cognito authentication.

Verifies Cognito user pool **access tokens** locally, following AWS's documented
steps (https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-verifying-a-jwt.html):

1. The signature is checked against the pool's public keys (JWKS), selected by
   the token's `kid`. Only RS256 is accepted.
2. `exp` must be in the future and `iss` must be this user pool.
3. `token_use` must be `access` (ID tokens are rejected).
4. `client_id` must be this application's app client.

Identity comes only from the verified `sub` claim. Nothing supplied by the
client is trusted.

If the pool is not configured, every token is rejected (fail closed): the
service starts and serves public routes, but no protected route can be reached.
"""

import logging
from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol, runtime_checkable

import jwt
from jwt import PyJWKClient

from app.core.config import settings

logger = logging.getLogger(__name__)

_ALGORITHMS = ["RS256"]
_REQUIRED_CLAIMS = ["exp", "iat", "iss", "sub", "token_use", "client_id"]
_JWKS_TIMEOUT_SECONDS = 5
_JWKS_CACHE_SECONDS = 3600


@dataclass(frozen=True)
class AuthenticatedUser:
    """
    A verified user. Only ever constructed from a verified token.

    Attributes:
        user_id: Cognito `sub` (stable, unique per user in the pool).
        email: Not present in access tokens; kept for interface compatibility.
        session_id: Token family identifier (`origin_jti`), when present.
    """

    user_id: str
    email: str | None = None
    session_id: str | None = None


@runtime_checkable
class AuthProvider(Protocol):
    """Interface every authentication provider implements."""

    def verify_token(self, token: str) -> AuthenticatedUser | None:
        """Return the user for a valid token, or None."""
        ...


class CognitoAuthService:
    """Verifies access tokens issued by one Cognito user pool for one app client."""

    def __init__(self, region: str, user_pool_id: str, app_client_id: str) -> None:
        self._issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
        self._app_client_id = app_client_id
        # Keys are fetched on first use and cached; an unknown `kid` triggers one
        # refresh, which is how Cognito key rotation is picked up.
        self._jwks_client = PyJWKClient(
            f"{self._issuer}/.well-known/jwks.json",
            cache_keys=True,
            lifespan=_JWKS_CACHE_SECONDS,
            timeout=_JWKS_TIMEOUT_SECONDS,
        )

    def verify_token(self, token: str) -> AuthenticatedUser | None:
        try:
            signing_key = self._jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=_ALGORITHMS,
                issuer=self._issuer,
                # Access tokens carry `client_id`, not `aud`; it is checked below.
                options={"require": _REQUIRED_CLAIMS, "verify_aud": False},
            )
        except jwt.PyJWTError as error:
            # Covers bad signature, expiry, wrong issuer, missing claims, an
            # unknown key and JWKS fetch failures. Never log the token.
            logger.debug("event=token_rejected reason=%s", type(error).__name__)
            return None

        if claims.get("token_use") != "access":
            logger.debug("event=token_rejected reason=not_access_token")
            return None

        if claims.get("client_id") != self._app_client_id:
            logger.debug("event=token_rejected reason=client_mismatch")
            return None

        user_id = claims.get("sub")
        if not isinstance(user_id, str) or not user_id:
            return None

        return AuthenticatedUser(
            user_id=user_id,
            session_id=claims.get("origin_jti"),
        )


class UnconfiguredAuthService:
    """Rejects every token. Used when no Cognito user pool is configured."""

    def verify_token(self, token: str) -> AuthenticatedUser | None:
        return None


@lru_cache(maxsize=1)
def get_auth_service() -> AuthProvider:
    """Return the process-wide authentication provider."""
    if settings.COGNITO_USER_POOL_ID and settings.COGNITO_APP_CLIENT_ID:
        logger.info("event=auth_provider_ready provider=cognito")
        return CognitoAuthService(
            region=settings.AWS_REGION,
            user_pool_id=settings.COGNITO_USER_POOL_ID,
            app_client_id=settings.COGNITO_APP_CLIENT_ID,
        )

    logger.warning(
        "event=auth_provider_unconfigured detail=all_protected_routes_return_401"
    )
    return UnconfiguredAuthService()
