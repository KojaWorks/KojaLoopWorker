"""Pure reconcile decisions, kept free of I/O so they're unit-testable.

Each tick the Manager cross-checks a BUSY slot's live tmux session against its card's
status and decides what to do. The card status is the source of truth: 'card left In
progress' is the done signal; 'process gone while card still In progress' is the crash
signal.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from enum import Enum

from .models import Card, CardStatus, Slot


class SlotAction(str, Enum):
    KEEP = "keep"                    # healthy, leave it
    REAP = "reap"                    # card left In progress — kill after grace
    CRASH_RECLAIM = "crash_reclaim"  # process dead while still In progress — release card
    HUNG_RECLAIM = "hung_reclaim"    # exceeded wallclock cap — kill + release card
    AUTH_RECLAIM = "auth_reclaim"    # alive but wedged at the login prompt — release card


def classify(
    slot: Slot,
    card: Card | None,
    alive: bool,
    now: datetime,
    wallclock_cap: timedelta,
    auth_failed: bool = False,
) -> tuple[SlotAction, str]:
    """Decide a BUSY slot's fate. `alive` = its tmux session has a non-shell process;
    `auth_failed` = its pane is showing claude's login/401 prompt. Grace timing for REAP
    is applied by the caller via slot.done_since."""
    if card is None:
        return SlotAction.REAP, "card no longer exists"
    if card.status != CardStatus.IN_PROGRESS:
        return SlotAction.REAP, f"card moved to {card.status.value}"
    # Card is still In progress from here on.
    if not alive:
        return SlotAction.CRASH_RECLAIM, "worker process gone while card still In progress"
    # Alive but stuck at the login prompt: the process won't recover on its own, so don't
    # let it hold the slot until the wallclock cap — reclaim now and let a fresh worker retry.
    if auth_failed:
        return SlotAction.AUTH_RECLAIM, "worker hit an auth failure (login prompt)"
    if slot.started_at and now - slot.started_at > wallclock_cap:
        return SlotAction.HUNG_RECLAIM, f"exceeded wallclock cap ({wallclock_cap})"
    return SlotAction.KEEP, "healthy"
