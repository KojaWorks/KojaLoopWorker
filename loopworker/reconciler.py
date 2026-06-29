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


def classify(
    slot: Slot,
    card: Card | None,
    alive: bool,
    now: datetime,
    wallclock_cap: timedelta,
) -> tuple[SlotAction, str]:
    """Decide a BUSY slot's fate. `alive` = its tmux session has a non-shell process.
    Grace timing for REAP is applied by the caller via slot.done_since."""
    if card is None:
        return SlotAction.REAP, "card no longer exists"
    if card.status != CardStatus.IN_PROGRESS:
        return SlotAction.REAP, f"card moved to {card.status.value}"
    # Card is still In progress from here on.
    if not alive:
        return SlotAction.CRASH_RECLAIM, "worker process gone while card still In progress"
    if slot.started_at and now - slot.started_at > wallclock_cap:
        return SlotAction.HUNG_RECLAIM, f"exceeded wallclock cap ({wallclock_cap})"
    return SlotAction.KEEP, "healthy"
