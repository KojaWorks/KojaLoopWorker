"""Mock-based tests for the Patch adapter's mapping and selection logic — no network.
The PostgREST verbs (_get/_patch/_post) are stubbed; everything above them is real."""
from pathlib import Path

import pytest

from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                               ScriptsConfig, WorkerConfig)
from loopworker.models import Card, CardStatus, Worker
from loopworker.backlog.patch import PatchAdapter


def _manifest():
    return Manifest(
        project_name="demo",
        project_dir=Path("/tmp/demo"),
        backlog=BacklogConfig(adapter="patch", portal="https://patch/x",
                              options={"api_base": "https://api.patch"}),
        brief=BriefConfig(source="patch-page",
                          ref="https://patch/app/loop-runner-instructions-"
                              "cfacaea7-59e9-4f40-8bba-44c10137a48e"),
        worker=WorkerConfig(mcp=["patch"]),
        slots=1,
        scripts=ScriptsConfig(),
    )


@pytest.fixture
def adapter(monkeypatch):
    monkeypatch.setenv("PATCH_SECRET_KEY", "test-key")
    return PatchAdapter(_manifest())


def _row(num, status="Backlog", **kw):
    base = {"id": f"u{num}", "id_2": num, "title": f"card {num}", "status": status,
            "priority": num, "area": [], "epic": None, "blocked_by": None,
            "assignee": None, "solved_in_pr": None}
    base.update(kw)
    return base


def test_relation_normalization(adapter):
    # single relation stored as bare uuid; multi as a list; absent as None.
    c = adapter._to_card(_row(1, assignee="w9", blocked_by=["a", "b"], epic="e1"))
    assert c.assignee == "w9"
    assert c.blocked_by == ["a", "b"]
    assert c.epic == "e1"
    c2 = adapter._to_card(_row(2, blocked_by="single-blocker"))
    assert c2.blocked_by == ["single-blocker"]  # scalar coerced to list
    c3 = adapter._to_card(_row(3))
    assert c3.assignee is None and c3.blocked_by == []


def test_list_workable_filters_and_sorts(adapter, monkeypatch):
    rows = [
        _row(1, priority=10),                                  # workable
        _row(2, priority=99, area=["epic"]),                   # epic -> skip
        _row(3, priority=50, assignee="w1"),                   # claimed -> skip
        _row(4, priority=80, status="In progress"),            # not backlog -> skip
        _row(5, priority=70, blocked_by=["u-unshipped"]),      # blocker not Shipped -> skip
        _row(9, priority=1, status="Shipped"),                 # a shipped card (blocker for 6)
        _row(6, priority=60, blocked_by=["u9"]),               # blocker shipped -> workable
    ]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    workable = adapter.list_workable()
    nums = [c.num for c in workable]
    assert nums == [6, 1]  # 6 (prio 60) before 1 (prio 10); others filtered out


def test_claim_returns_true_when_row_updated(adapter, monkeypatch):
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: [_row(1, status="In progress")])
    assert adapter.claim(Card("u1", 1, "t", CardStatus.BACKLOG, 1), Worker("w1", "ada")) is True


def test_claim_returns_false_when_no_row(adapter, monkeypatch):
    # atomic claim lost: assignee=is.null filter matched nothing -> empty list
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: [])
    assert adapter.claim(Card("u1", 1, "t", CardStatus.BACKLOG, 1), Worker("w1", "ada")) is False


def test_brief_points_worker_at_patch_page(adapter):
    brief = adapter.get_brief()
    assert "cfacaea7-59e9-4f40-8bba-44c10137a48e" in brief
    assert "get_page" in brief
