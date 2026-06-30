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

    @property
    def is_epic(self) -> bool:
        return "epic" in self.area


@dataclass
class Worker:
    """A row in the backlog's worker registry (Patch `loop_workers`)."""
    id: str
    name: str
    role: str = "generic"
    notes: str = ""
    last_active: datetime | None = None


class SlotState(str, Enum):
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
