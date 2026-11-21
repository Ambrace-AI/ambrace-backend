"""Request and response shapes for the signed-in user's profile (/api/v1/me)."""

import datetime
import unicodedata
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

from app.db.profile_repository import (
    MAX_CLASS_LEVEL,
    MIN_CLASS_LEVEL,
    Board,
)

# Characters that reorder surrounding text when displayed. They are format
# characters (like the joiners Indian scripts need, which stay allowed), but
# their only use in a name or address is to disguise it.
_BIDI_CONTROLS = frozenset("\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")


def _reject_control_characters(value: str, *, allow_newline: bool = False) -> str:
    """Profile text is shown back in pages, reports and exports; keep it printable."""
    for character in value:
        if allow_newline and character == "\n":
            continue
        if unicodedata.category(character) == "Cc" or character in _BIDI_CONTROLS:
            raise ValueError("must not contain control characters")
    return value


class ProfileUpdateRequest(BaseModel):
    """Everything onboarding collects. Sending it again replaces the profile.

    The user id is NOT part of this request: it comes from the verified token.
    Unknown fields are rejected so a client cannot set server-owned values.
    """

    model_config = ConfigDict(extra="forbid")

    name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)
    ]
    class_level: int = Field(ge=MIN_CLASS_LEVEL, le=MAX_CLASS_LEVEL, strict=True)
    board: Board
    school_name: Annotated[str, StringConstraints(max_length=150)] | None = None
    school_address: Annotated[str, StringConstraints(max_length=300)] | None = None

    @field_validator("name", "school_name", mode="after")
    @classmethod
    def single_line_text(cls, value: str | None) -> str | None:
        return None if value is None else _reject_control_characters(value)

    @field_validator("school_address", mode="after")
    @classmethod
    def multi_line_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _reject_control_characters(value, allow_newline=True)

    @field_validator("school_name", "school_address", mode="after")
    @classmethod
    def blank_means_absent(cls, value: str | None) -> str | None:
        """An empty optional box in a form is the same as leaving it out."""
        if value is None:
            return None
        return value.strip() or None


class ProfileResponse(BaseModel):
    """The profile as the API publishes it.

    Deliberately separate from the stored model: a field added to storage later
    (a role, a consent record) is not published until it is added here.
    """

    model_config = ConfigDict(from_attributes=True)

    name: str
    class_level: int
    board: Board
    school_name: str | None
    school_address: str | None
    created_at: datetime.datetime
    updated_at: datetime.datetime


class MeResponse(BaseModel):
    """The signed-in user and their profile, if onboarding has been completed."""

    user_id: str
    onboarding_complete: bool
    profile: ProfileResponse | None
