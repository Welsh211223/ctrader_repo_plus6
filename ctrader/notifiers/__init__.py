# package init (explicit re-export for Ruff)
from .discord import send as send

__all__ = ["send"]
