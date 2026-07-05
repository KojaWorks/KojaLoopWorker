"""Patch backlog adapter — talks to Patch's PostgREST API directly (the Manager is not
a Claude and never uses the MCP).

Schema facts (from the live workspace + KojaPatch source):
  * REST at {api_base}/rest/v1/<table>; auth = apikey (anon) + Authorization: Bearer <jwt>.
  * roadmap.id_2 is the ~NNN card number (real column); id (uuid) is the primary key.
  * relations are scalar columns: single -> uuid, multi -> jsonb array of uuids. We
    normalize either shape to a list. roadmap.assignee -> loop_workers (to-one);
    roadmap.blocked_by / epic -> roadmap.
  * area (multiselect) is a jsonb array of strings; "epic" in area marks an umbrella.

Auth: set PATCH_PAT in the Manager's env — a Personal Access Token minted once in
Patch (Settings -> Tokens). The Manager exchanges it (POST /functions/v1/pat-exchange)
for a SHORT-LIVED owner JWT and talks to PostgREST as that owner — RLS-scoped, never
the service_role god key. It re-exchanges as the JWT nears expiry (and on a 401), which
also re-checks revocation, so a revoked PAT stops working within ~the session lifetime.
The apikey header is the deployment's PUBLIC anon key (manifest [backlog.patch].anon_key);
Kong needs it to route, but it grants nothing on its own.
"""
from __future__ import annotations

import os
import re
import time
from collections.abc import Callable
from datetime import datetime, timezone

import httpx

from ..config import HostConfig, Manifest
from ..models import Card, CardStatus, ProjectRow, Worker
from .base import BacklogAdapter

_UUID_TAIL = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.I)

# PAT-exchange backoff: every merge to main recreates the prod stack, so a Manager
# (re)start colliding with a 5xx window is routine. Retry transient backend errors
# with capped exponential backoff before giving up (a genuinely bad PAT still 401s fast).
_RETRY_BASE_SECONDS = 10.0
_RETRY_CAP_SECONDS = 120.0
_RETRY_BUDGET_SECONDS = 600.0


def brief_pointer(ref: str) -> str:
    """A worker-facing pointer to a Patch-page brief: tell the worker to read it via the
    MCP rather than fetching it ourselves. Empty ref → empty string (no pointer)."""
    if not ref:
        return ""
    m = _UUID_TAIL.search(ref)
    page = m.group(1) if m else ref
    return (
        f"Your loop instructions are Patch page {page} ({ref}). "
        f"Read it with the Patch MCP `get_page` tool before starting."
    )


class PatchAdapter(BacklogAdapter):
    def __init__(
        self,
        manifest: Manifest | None = None,
        *,
        api_base: str = "",
        anon_key: str | None = None,
        worker_manager: str = "",
        roadmap_table: str = "roadmap",
        workers_table: str = "loop_workers",
        projects_table: str = "projects",
        log: Callable[[str], None] = lambda msg: None,
        notify: Callable[[str, str], None] = lambda key, msg: None,
        retry_budget_seconds: float = _RETRY_BUDGET_SECONDS,
    ) -> None:
        super().__init__(manifest)
        if manifest is not None:  # single-project mode: connection lives in the manifest
            opts = manifest.backlog.options
            api_base = opts.get("api_base", "")
            anon_key = opts.get("anon_key")
            worker_manager = manifest.worker_manager
            roadmap_table = opts.get("roadmap_table", "roadmap")
            workers_table = opts.get("workers_table", "loop_workers")
            projects_table = opts.get("projects_table", "projects")
        api_base = (api_base or "").rstrip("/")
        if not api_base:
            raise ValueError("api_base is required")
        if not anon_key:
            raise ValueError(
                "anon_key is required — the deployment's PUBLIC anon key, which "
                "PostgREST/Kong needs as the apikey header."
            )
        pat = os.environ.get("PATCH_PAT")
        if not pat:
            raise RuntimeError(
                "PATCH_PAT is not set — mint a Personal Access Token in Patch "
                "(Settings -> Tokens) and put it in the Manager's .env. The Manager "
                "exchanges it for a short-lived owner session; it never uses service_role."
            )
        self.roadmap = roadmap_table
        self.workers = workers_table
        self.projects = projects_table
        self.worker_manager = worker_manager  # "" = serve every project (back-compat)
        self._log = log
        self._notify = notify
        self._retry_budget = retry_budget_seconds
        self._pat = pat
        self._anon = anon_key
        self._exchange_url = f"{api_base}/functions/v1/pat-exchange"
        self._access_token: str | None = None
        self._access_exp = 0.0  # unix seconds
        # apikey is the public anon key (Kong routing); Authorization is set per
        # exchange in _ensure_token. Content-Type for the JSON body.
        self._client = httpx.Client(
            base_url=f"{api_base}/rest/v1",
            headers={"apikey": anon_key, "Content-Type": "application/json"},
            timeout=30,
        )
        self._ensure_token()  # fail fast at startup if the PAT is bad

    @classmethod
    def from_host(
        cls,
        host: HostConfig,
        *,
        log: Callable[[str], None] = lambda msg: None,
        notify: Callable[[str, str], None] = lambda key, msg: None,
    ) -> "PatchAdapter":
        """Build the shared adapter for host mode — connection from HostConfig, no
        per-project manifest. log/notify surface retry progress and give-up alerts."""
        return cls(
            api_base=host.api_base, anon_key=host.anon_key, worker_manager=host.worker_manager,
            roadmap_table=host.roadmap_table, workers_table=host.workers_table,
            projects_table=host.projects_table, log=log, notify=notify,
        )

    # --- reads -------------------------------------------------------------
    def list_projects(self) -> list[ProjectRow]:
        """The projects this host serves: rows in `projects` whose worker_manager is ours."""
        rows = self._get(self.projects, {"worker_manager": f"eq.{self.worker_manager}", "select": "*"})
        return [
            ProjectRow(
                id=r["id"], name=r.get("name") or "", repo=r.get("repo"),
                default_branch=r.get("default_branch") or "main",
                slots=r.get("slots"), hot=bool(r.get("hot")), brief_ref=r.get("brief_ref"),
                weight=float(r["weight"]) if r.get("weight") else 1.0,
                model=r.get("model") or None,
            )
            for r in rows
        ]

    def list_workable(self) -> list[Card]:
        cards = [self._to_card(r) for r in self._get(self.roadmap, {"select": "*"})]
        by_id = {c.id: c for c in cards}
        served = self._served_project_ids()
        workable = [
            c for c in cards
            if c.status == CardStatus.BACKLOG
            and c.assignee is None
            and not c.is_epic
            and self._unblocked(c, by_id)
            and self._in_scope(c, served)
        ]
        # priority desc; ties broken by oldest card first (lowest id_2) so the queue is
        # deterministic — equal-priority (incl. all unranked → 0) cards don't flap on
        # PostgREST's physical row order.
        workable.sort(key=lambda c: (-c.priority, c.num))
        return workable

    def _served_project_ids(self) -> set[str] | None:
        """The projects this Manager serves: rows in `projects` whose worker_manager is
        ours. None = no filtering (worker_manager unset → serve every project, the old
        single-project behaviour)."""
        if not self.worker_manager:
            return None
        rows = self._get(self.projects, {"worker_manager": f"eq.{self.worker_manager}", "select": "id"})
        return {r["id"] for r in rows}

    @staticmethod
    def _in_scope(card: Card, served: set[str] | None) -> bool:
        if served is None:
            return True                      # not filtering by project
        if card.project is None:
            return len(served) == 1          # sole-project host adopts a not-yet-tagged card
        return card.project in served

    def get_card(self, num: int) -> Card | None:
        rows = self._get(self.roadmap, {"id_2": f"eq.{num}", "select": "*", "limit": "1"})
        return self._to_card(rows[0]) if rows else None

    def cards_in_progress(self) -> list[Card]:
        rows = self._get(self.roadmap, {"status": f"eq.{CardStatus.IN_PROGRESS.value}", "select": "*"})
        return [self._to_card(r) for r in rows]

    # --- writes ------------------------------------------------------------
    def register_worker(self, name: str, role: str = "generic", notes: str = "") -> Worker:
        """Upsert the worker row for this (stable, per-slot) name: reuse it if it
        exists, else create it. Keeps loop_workers to one row per slot rather than one
        per card. Safe without a DB unique constraint — the single Manager (lockfile)
        spawns sequentially, so there's no concurrent insert race on a name."""
        now = datetime.now(timezone.utc)
        fields = {"role": role, "notes": notes, "last_active": now.isoformat()}
        existing = self._get(self.workers, {"name": f"eq.{name}", "select": "id", "limit": "1"})
        if existing:
            wid = existing[0]["id"]
            self._patch(self.workers, {"id": f"eq.{wid}"}, fields)
        else:
            wid = self._post(self.workers, {"name": name, **fields})[0]["id"]
        return Worker(id=wid, name=name, role=role, notes=notes, last_active=now)

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
            return brief_pointer(brief.ref)
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
            status=CardStatus.parse(r.get("status")),
            priority=float(r.get("priority") or 0),
            area=list(r.get("area") or []),
            epic=self._rel_one(r.get("epic")),
            blocked_by=self._rel_list(r.get("blocked_by")),
            assignee=self._rel_one(r.get("assignee")),
            solved_in_pr=r.get("solved_in_pr"),
            project=self._rel_one(r.get("project")),
            model=r.get("model") or None,
        )

    # Auth ----
    def _ensure_token(self, *, force: bool = False) -> None:
        """Exchange the PAT for a fresh owner JWT when missing/near-expiry/forced.
        Re-exchanging (vs. silently reusing) is how revocation takes effect. Transient
        backend errors (5xx / connect failures) are retried with capped exponential
        backoff — a Manager (re)start colliding with a prod redeploy shouldn't be fatal.
        A genuine auth rejection (401/403) still fails fast: the PAT is bad."""
        if not force and self._access_token and time.time() < self._access_exp - 60:
            return
        elapsed = 0.0
        delay = _RETRY_BASE_SECONDS
        while True:
            err = self._try_exchange()
            if err is None:
                return
            if elapsed >= self._retry_budget:
                msg = (f"Patch backend still unreachable ({err}) after ~{int(elapsed)}s of "
                       "retries — giving up.")
                self._notify("patch-unreachable", f"LoopWorker: {msg}")
                raise RuntimeError(msg)
            wait = min(delay, self._retry_budget - elapsed)
            self._log(f"Patch pat-exchange failed ({err}); retrying in {int(wait)}s")
            time.sleep(wait)
            elapsed += wait
            delay = min(delay * 2, _RETRY_CAP_SECONDS)

    def _try_exchange(self) -> str | None:
        """One PAT-exchange attempt. Returns None on success (token cached); a short
        reason string on a transient failure the caller should retry. Raises on a genuine
        auth rejection (401/403) or any other non-transient error (unexpected 4xx / bad
        body) — those aren't worth retrying."""
        try:
            r = httpx.post(
                self._exchange_url,
                json={"token": self._pat},
                headers={"apikey": self._anon, "Content-Type": "application/json"},
                timeout=30,
            )
        except httpx.TransportError as e:
            return f"connect error: {e!r}"
        if r.status_code in (401, 403):
            raise RuntimeError(
                "Patch rejected PATCH_PAT (revoked or wrong). Mint a new token in "
                "Settings -> Tokens and update the Manager's .env."
            )
        if r.status_code >= 500:
            return f"HTTP {r.status_code}"
        r.raise_for_status()  # unexpected 4xx -> surface (not transient, not an auth reject)
        body = r.json()
        self._access_token = body["access_token"]
        self._access_exp = float(body.get("expires_at") or 0)
        self._client.headers["Authorization"] = f"Bearer {self._access_token}"
        return None

    # PostgREST verbs ----
    def _request(self, method: str, path: str, **kw) -> httpx.Response:
        self._ensure_token()
        r = self._client.request(method, path, **kw)
        if r.status_code == 401:  # token expired mid-flight or just revoked — re-exchange once
            self._ensure_token(force=True)
            r = self._client.request(method, path, **kw)
        r.raise_for_status()
        return r

    def _get(self, table: str, params: dict) -> list[dict]:
        return self._request("GET", f"/{table}", params=params).json()

    def _post(self, table: str, body: dict) -> list[dict]:
        return self._request("POST", f"/{table}", json=body, headers={"Prefer": "return=representation"}).json()

    def _patch(self, table: str, params: dict, body: dict) -> list[dict]:
        return self._request(
            "PATCH", f"/{table}", params=params, json=body, headers={"Prefer": "return=representation"}
        ).json()
