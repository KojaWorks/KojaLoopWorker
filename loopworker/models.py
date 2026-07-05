"""Value types shared across the Manager.

The card statuses are the EXACT strings from the Patch `roadmap.status` select; an
adapter for another backlog maps its own states onto this enum.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class CardStatus(str, Enum):
    IDEA = "Idea"
    NEEDS_REFINEMENT = "Needs refinement"
    BACKLOG = "Backlog"
    IN_PROGRESS = "In progress"
    SHIPPED = "Shipped"
    INVALID_CLOSED = "Invalid/Closed"
    OTHER = "__other__"  # any status the roadmap has that we don't model (Epic, Next, …):
    #                      never workable / in-progress / shipped, so the Manager ignores it

    @classmethod
    def parse(cls, value: object) -> "CardStatus":
        """Map a raw status string to a member, bucketing anything unknown as OTHER so
        one oddly-statused card can't crash a whole tick."""
        if not value:
            return cls.BACKLOG
        try:
            return cls(value)
        except ValueError:
            return cls.OTHER


@dataclass
class Card:
    """A backlog item. `num` is the human id (~NNN); `id` is the backend primary key."""
    id: str
    num: int
    title: str
    status: CardStatus
    priority: float
    area: list[str] = field(default_factory=list)
    epic: str | None = None              # id of the umbrella card, if any
    blocked_by: list[str] = field(default_factory=list)  # ids of blocker cards
    assignee: str | None = None          # id of the owning worker, if claimed
    solved_in_pr: str | None = None
    project: str | None = None           # id of the projects row this card belongs to
    model: str | None = None             # CLI model alias override (opus/fable/sonnet/haiku); "" = project default

    @property
    def is_epic(self) -> bool:
        return "epic" in self.area


@dataclass
class ProjectRow:
    """A row in the shared `projects` registry: a project this host may serve."""
    id: str
    name: str
    repo: str | None = None              # git URL to clone
    default_branch: str = "main"
    slots: int | None = None             # override the manifest's slot count
    hot: bool = False                    # keep a warm pool vs cold-provision per card
    brief_ref: str | None = None         # optional Patch-page brief (alt to the repo BRIEF.md)
    weight: float = 1.0                  # relative cost per slot (e.g. a warm Supabase stack
    #                                      costs more RAM than a cold native build) — the host
    #                                      slot budget (max_slots) is spent in these units
    model: str | None = None             # default CLI model alias for this project's workers; "" = CLI default


@dataclass
class Worker:
    """A row in the backlog's worker registry (Patch `loop_workers`)."""
    id: str
    name: str
    role: str = "generic"
    notes: str = ""
    last_active: datetime | None = None


class SlotState(str, Enum):
    COLD = "cold"        # exists but not provisioned; a cold pool provisions on demand
    IDLE = "idle"        # provisioned, no worker
    BUSY = "busy"        # a worker is running in it
    BROKEN = "broken"    # provision/reset failed; needs attention


@dataclass
class Slot:
    """A warm (worktree, port, stack) the Manager reuses across cards."""
    index: int
    dir: str
    port: int
    state: SlotState = SlotState.IDLE
    activity: str = "new"        # human-readable current step (provisioning, resetting, running ~N, …)
    session: str | None = None   # tmux session name of the worker, when BUSY
    card_num: int | None = None  # the ~NNN being worked, when BUSY
    worker_id: str | None = None # loop_workers row id of the running worker
    started_at: datetime | None = None
    done_since: datetime | None = None  # when its card first left In progress (reap grace clock)
    retiring: bool = False       # slot count was lowered while this slot was BUSY: tear it
    #                              down (don't return it to the pool) once its card finishes
    port_reported: bool = False  # the project's provision/reset echoed LOOPWORKER_PORT, i.e.
    #                              it actually binds a port (a web stack). Native/stackless
    #                              projects never set this, so the dashboard hides the port.
