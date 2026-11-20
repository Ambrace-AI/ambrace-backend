"""
Authentication for the Ambrace backend (Amazon Cognito).

Usage:
    from app.core.auth import CurrentUser, OptionalUser, AuthenticatedUser

    @router.get("/protected")
    async def protected(user: CurrentUser):
        return {"user_id": user.user_id}

Swapping providers:
    Implement `AuthProvider.verify_token` and return it from
    `get_auth_service()` in cognito.py. Routes do not change.
"""

from .cognito import (
    AuthenticatedUser,
    AuthProvider,
    CognitoAuthService,
    UnconfiguredAuthService,
    get_auth_service,
)
from .dependencies import (
    CurrentUser,
    OptionalUser,
    get_current_user,
    get_current_user_optional,
)

__all__ = [
    "AuthenticatedUser",
    "AuthProvider",
    "CognitoAuthService",
    "UnconfiguredAuthService",
    "get_auth_service",
    "CurrentUser",
    "OptionalUser",
    "get_current_user",
    "get_current_user_optional",
]
