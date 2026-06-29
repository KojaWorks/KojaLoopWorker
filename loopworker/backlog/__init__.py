"""Backlog adapters. v1 ships Patch; the interface is in `base`."""
from __future__ import annotations

from ..config import Manifest
from .base import BacklogAdapter


def build_adapter(manifest: Manifest) -> BacklogAdapter:
    """Construct the adapter named by the manifest's `backlog.adapter`."""
    name = manifest.backlog.adapter
    if name == "patch":
        from .patch import PatchAdapter
        return PatchAdapter(manifest)
    raise ValueError(f"unknown backlog adapter: {name!r} (only 'patch' in v1)")
