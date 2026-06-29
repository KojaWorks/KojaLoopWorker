from datetime import datetime, timedelta, timezone

from loopworker.models import Card, CardStatus, Slot, SlotState
from loopworker.reconciler import SlotAction, classify

NOW = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
CAP = timedelta(minutes=90)


def _slot(started_at=NOW, **kw):
    return Slot(index=0, dir="/tmp/slot-0", port=54400, state=SlotState.BUSY,
                session="lw-x-1", card_num=1, started_at=started_at, **kw)


def _card(status=CardStatus.IN_PROGRESS):
    return Card(id="u1", num=1, title="t", status=status, priority=1)


def test_card_gone_is_reap():
    action, _ = classify(_slot(), None, True, NOW, CAP)
    assert action == SlotAction.REAP


def test_card_left_in_progress_is_reap():
    action, _ = classify(_slot(), _card(CardStatus.SHIPPED), True, NOW, CAP)
    assert action == SlotAction.REAP


def test_healthy_is_keep():
    action, _ = classify(_slot(), _card(), True, NOW, CAP)
    assert action == SlotAction.KEEP


def test_dead_while_in_progress_is_crash():
    action, reason = classify(_slot(), _card(), False, NOW, CAP)
    assert action == SlotAction.CRASH_RECLAIM
    assert "gone" in reason


def test_over_wallclock_is_hung():
    slot = _slot(started_at=NOW - timedelta(minutes=91))
    action, _ = classify(slot, _card(), True, NOW, CAP)
    assert action == SlotAction.HUNG_RECLAIM
