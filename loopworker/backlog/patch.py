"""Patch backlog adapter — talks to Patch's PostgREST API directly (the Manager is not
a Claude and never uses the MCP).

Schema facts (from the live workspace + KojaPatch source):
  * REST at {api_base}/rest/v1/<table>; auth = apikey + Authorization: Bearer <key>.
  * roadmap.id_2 is the ~NNN card number (real column); id (uuid) is the primary key.
  * relations are scalar columns: single -> uuid, multi -> jsonb array of uuids. We
    normalize either shape to a list. roadmap.assignee -> loop_workers (to-one);
    roadmap.blocked_by / epic -> roadmap.
  * area (multiselect) is a jsonb array of strings; "epic" in area marks an umbrella.

Auth: set PATCH_SECRET_KEY (Supabase service_role key) in the Manager's env. It bypasses
RLS — that's required for the Manager to read/write the roadmap, and is why it lives in
.env, never in the repo.
"""
from __future__ import annotations

import os
import re
from datetime import datetime, timezone

import httpx

from ..config import Manifest
from ..models import Card, CardStatus, Worker
from .base import BacklogAdapter

_UUID_TAIL = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.I)


class PatchAdapter(BacklogAdapter):
    def __init__(self, manifest: Manifest) -> None:
        super().__init__(manifest)
        opts = manifest.backlog.options
        api_base = opts.get("api_base", "").rstrip("/")
        if not api_base:
            raise ValueError("manifest [backlog.patch].api_base is required")
        key = os.environ.get("PATCH_SECRET_KEY") or os.environ.get("PATCH_SERVICE_TOKEN")
        if not key:
            raise RuntimeError(
                "PATCH_SECRET_KEY (Supabase service_role key) is not set — "
                "the Manager needs it to read/write the Patch backlog."
            )
        self.roadmap = opts.get("roadmap_table", "roadmap")
        self.workers = opts.get("workers_table", "loop_workers")
        self._client = httpx.Client(
            base_url=f"{api_base}/rest/v1",
            headers={
                "apikey": key,
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            },
            timeout=30,
        )

    # --- reads -------------------------------------------------------------
    def list_workable(self) -> list[Card]:
        cards = [self._to_card(r) for r in self._get(self.roadmap, {"select": "*"})]
        by_id = {c.id: c for c in cards}
        workable = [
            c for c in cards
            if c.status == CardStatus.BACKLOG
            and c.assignee is None
            and not c.is_epic
            and self._unblocked(c, by_id)
        ]
        workable.sort(key=lambda c: c.priority, reverse=True)
        return workable

    def get_card(self, num: int) -> Card | None:
        rows = self._get(self.roadmap, {"id_2": f"eq.{num}", "select": "*", "limit": "1"})
        return self._to_card(rows[0]) if rows else None

    def cards_in_progress(self) -> list[Card]:
        rows = self._get(self.roadmap, {"status": f"eq.{CardStatus.IN_PROGRESS.value}", "select": "*"})
        return [self._to_card(r) for r in rows]

    # --- writes ------------------------------------------------------------
    def register_worker(self, name: str, role: str = "generic", notes: str = "") -> Worker:
        now = datetime.now(timezone.utc)
        rows = self._post(
            self.workers,
            {"name": name, "role": role, "notes": notes, "last_active": now.isoformat()},
        )
        row = rows[0]
        return Worker(id=row["id"], name=name, role=role, notes=notes, last_active=now)

    def claim(self, card: Card, worker: Worker) -> bool:
        """Atomic claim: the assignee=is.null filter makes the PATCH match zero rows if
        someone already took it. Returns True iff we won."""
        rows = self._patch(
            self.roadmap,
            {"id": f"eq.{card.id}", "assignee": "is.null"},
            {"assignee": worker.id, "status": CardStatus.IN_PROGRESS.value},
        )
        return bool(rows)

    def release(self, card: Card, *, note: str | None = None) -> None:
        # note → card body is deferred (needs the blocks-table write path); the Manager
        # logs the reason in the meantime.
        self._patch(
            self.roadmap,
            {"id": f"eq.{card.id}"},
            {"assignee": None, "status": CardStatus.BACKLOG.value},
        )

    # --- brief -------------------------------------------------------------
    def get_brief(self) -> str:
        """A prompt fragment telling the Worker where its loop instructions live. For a
        Patch page we point the Worker at the MCP rather than fetching it ourselves."""
        brief = self.manifest.brief
        inline = self._read_brief_generic(brief)
        if inline is not None:
            return inline
        if brief.source == "patch-page":
            m = _UUID_TAIL.search(brief.ref)
            page = m.group(1) if m else brief.ref
            return (
                f"Your loop instructions are Patch page {page} ({brief.ref}). "
                f"Read it with the Patch MCP `get_page` tool before starting."
            )
        raise ValueError(f"unsupported brief source: {brief.source!r}")

    # --- internals ---------------------------------------------------------
    def _unblocked(self, card: Card, by_id: dict[str, Card]) -> bool:
        for bid in card.blocked_by:
            blocker = by_id.get(bid)
            if blocker is None or blocker.status != CardStatus.SHIPPED:
                return False
        return True

    @staticmethod
    def _rel_list(value) -> list[str]:
        if value is None:
            return []
        return list(value) if isinstance(value, list) else [value]

    @staticmethod
    def _rel_one(value) -> str | None:
        if value is None:
            return None
        return value[0] if isinstance(value, list) else value

    def _to_card(self, r: dict) -> Card:
        return Card(
            id=r["id"],
            num=r["id_2"],
            title=r.get("title") or "",
            status=CardStatus(r["status"]) if r.get("status") else CardStatus.BACKLOG,
            priority=float(r.get("priority") or 0),
            area=list(r.get("area") or []),
            epic=self._rel_one(r.get("epic")),
            blocked_by=self._rel_list(r.get("blocked_by")),
            assignee=self._rel_one(r.get("assignee")),
            solved_in_pr=r.get("solved_in_pr"),
        )

    # PostgREST verbs ----
    def _get(self, table: str, params: dict) -> list[dict]:
        r = self._client.get(f"/{table}", params=params)
        r.raise_for_status()
        return r.json()

    def _post(self, table: str, body: dict) -> list[dict]:
        r = self._client.post(f"/{table}", json=body, headers={"Prefer": "return=representation"})
        r.raise_for_status()
        return r.json()

    def _patch(self, table: str, params: dict, body: dict) -> list[dict]:
        r = self._client.patch(
            f"/{table}", params=params, json=body, headers={"Prefer": "return=representation"}
        )
        r.raise_for_status()
        return r.json()
