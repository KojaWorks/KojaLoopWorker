"""The backlog-adapter interface.

The Manager is non-AI and never touches the MCP — an adapter talks to its backlog's
HTTP API directly. Keep this surface narrow; new backends (Notion, GitHub) implement
the same six operations.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path

import httpx

from ..config import BriefConfig, Manifest
from ..models import Card, CardStatus, Worker


class BacklogAdapter(ABC):
    def __init__(self, manifest: Manifest | None = None) -> None:
        # None in host mode: the connection comes from HostConfig, not a project manifest.
        self.manifest = manifest

    # --- reads -------------------------------------------------------------
    @abstractmethod
    def list_workable(self) -> list[Card]:
        """Actionable cards, highest priority first: Backlog, unassigned, not an
        epic, and every direct `blocked_by` target already Shipped."""

    @abstractmethod
    def get_card(self, num: int) -> Card | None:
        """Re-read one card by its ~NNN id (for reconciling live workers)."""

    @abstractmethod
    def cards_in_progress(self) -> list[Card]:
        """Every card currently In progress (the reconciler cross-checks these
        against live tmux sessions)."""

    # --- writes (claim lifecycle) -----------------------------------------
    @abstractmethod
    def register_worker(self, name: str, role: str = "generic", notes: str = "") -> Worker:
        """Upsert the worker row for `name` and return it — reuse the existing row if
        present, else create one. Names are stable per slot, so this keeps the worker
        registry to one row per slot instead of one per card."""

    @abstractmethod
    def claim(self, card: Card, worker: Worker) -> bool:
        """Set assignee=worker + status=In progress. Returns False if the card was
        already claimed by someone else (lost race) — re-read to confirm."""

    @abstractmethod
    def release(self, card: Card, *, note: str | None = None) -> None:
        """Crash recovery: clear assignee, move back to Backlog, optionally log a
        note onto the card body."""

    # --- brief -------------------------------------------------------------
    @abstractmethod
    def get_brief(self) -> str:
        """The worker brief / loop instructions, resolved per manifest [brief]."""

    # --- dashboard ---------------------------------------------------------
    def card_links(self) -> dict[str, str]:
        """Map of str(card num) -> a clickable backlog URL for that card, for the
        dashboard to linkify ~NNN references. Default: no links (an adapter that can
        build them overrides this)."""
        return {}

    # --- shared helpers ----------------------------------------------------
    def _read_brief_generic(self, brief: BriefConfig) -> str | None:
        """Handle the backend-independent brief sources. Returns None for sources a
        subclass must resolve itself (e.g. patch-page)."""
        if brief.source == "repo-file":
            return (self.manifest.project_dir / brief.ref).read_text()
        if brief.source == "url":
            return httpx.get(brief.ref, timeout=30, follow_redirects=True).text
        return None
