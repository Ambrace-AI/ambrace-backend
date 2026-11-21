"""The signed-in user's profile and whether they have finished onboarding."""

from app.db.profile_repository import ProfileRepository, UserProfile
from app.schemas.profile import MeResponse, ProfileResponse, ProfileUpdateRequest


class ProfileService:
    def __init__(self, repository: ProfileRepository):
        self.repository = repository

    @staticmethod
    def _response(user_id: str, profile: UserProfile | None) -> MeResponse:
        # A profile can only be saved with every required field present, so
        # having one is exactly what "onboarding complete" means.
        return MeResponse(
            user_id=user_id,
            onboarding_complete=profile is not None,
            profile=ProfileResponse.model_validate(profile) if profile else None,
        )

    async def get_me(self, user_id: str) -> MeResponse:
        return self._response(user_id, await self.repository.get(user_id))

    async def save_profile(
        self, user_id: str, request: ProfileUpdateRequest
    ) -> MeResponse:
        profile = UserProfile(**request.model_dump())
        return self._response(user_id, await self.repository.save(user_id, profile))
