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
                              options={"api_base": "https://api.patch", "anon_key": "anon-test"}),
        brief=BriefConfig(source="patch-page",
                          ref="https://patch/app/loop-runner-instructions-"
                              "cfacaea7-59e9-4f40-8bba-44c10137a48e"),
        worker=WorkerConfig(mcp=["patch"]),
        slots=1,
        scripts=ScriptsConfig(),
    )


@pytest.fixture
def adapter(monkeypatch):
    monkeypatch.setenv("PATCH_PAT", "pat_test")
    # Don't hit the network exchanging the PAT at construction; the mapping/selection
    # tests stub _get/_patch directly, above the auth layer.
    monkeypatch.setattr(PatchAdapter, "_ensure_token", lambda self, force=False: None)
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


class _ExResp:
    def __init__(self, token):
        self.status_code = 200
        self._token = token
    def raise_for_status(self): pass
    def json(self): return {"access_token": self._token, "expires_at": 9_999_999_999}


def test_exchange_sets_bearer_and_caches(monkeypatch):
    # __init__ exchanges the PAT once; a far-future expiry means no re-exchange.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    posts = []
    def fake_post(url, json, headers, timeout):
        posts.append((url, json["token"], headers.get("apikey")))
        return _ExResp("jwt-1")
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post", fake_post)
    a = PatchAdapter(_manifest())
    assert a._client.headers["Authorization"] == "Bearer jwt-1"
    assert posts == [("https://api.patch/functions/v1/pat-exchange", "pat_abc", "anon-test")]
    a._ensure_token()                       # cached -> no second exchange
    assert len(posts) == 1


def test_card_status_parse_tolerates_unknown():
    assert CardStatus.parse("Backlog") == CardStatus.BACKLOG
    assert CardStatus.parse("In progress") == CardStatus.IN_PROGRESS
    assert CardStatus.parse(None) == CardStatus.BACKLOG
    assert CardStatus.parse("Epic") == CardStatus.OTHER       # unknown -> bucketed, not a crash
    assert CardStatus.parse("Next") == CardStatus.OTHER


def test_unknown_status_card_is_skipped_not_crashing(adapter, monkeypatch):
    rows = [_row(1, priority=10), _row(2, priority=99, status="Epic")]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert [c.num for c in adapter.list_workable()] == [1]    # Epic card ignored, no ValueError


def test_name_for_slot_is_stable_and_wraps():
    from loopworker.names import name_for_slot, _NAMES
    assert name_for_slot(0) == "ada"
    assert name_for_slot(1) == "babbage"
    assert name_for_slot(len(_NAMES)) == "ada2"        # wraps with a cycle suffix
    assert name_for_slot(0) == name_for_slot(0)         # deterministic


def test_register_worker_reuses_existing_row(adapter, monkeypatch):
    calls = {"post": 0, "patch": 0}
    monkeypatch.setattr(adapter, "_get", lambda t, p: [{"id": "w-ada"}])  # row exists
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: calls.__setitem__("patch", calls["patch"] + 1) or [{}])
    monkeypatch.setattr(adapter, "_post", lambda t, b: calls.__setitem__("post", calls["post"] + 1) or [{"id": "new"}])
    w = adapter.register_worker("ada", notes="~423: x")
    assert w.id == "w-ada" and calls == {"post": 0, "patch": 1}   # reused, not inserted


def test_register_worker_inserts_when_absent(adapter, monkeypatch):
    monkeypatch.setattr(adapter, "_get", lambda t, p: [])          # no row yet
    monkeypatch.setattr(adapter, "_post", lambda t, b: [{"id": "w-new"}])
    w = adapter.register_worker("babbage")
    assert w.id == "w-new"


def test_request_retries_once_on_401(monkeypatch):
    # An expired/revoked JWT surfaces as a 401; _request re-exchanges and retries.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    exchanges = []
    def fake_post(url, json, headers, timeout):
        exchanges.append(1); return _ExResp(f"jwt-{len(exchanges)}")
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post", fake_post)
    a = PatchAdapter(_manifest())           # exchange #1
    codes = [401, 200]
    class _ReqResp:
        def __init__(self, code): self.status_code = code
        def raise_for_status(self): pass
        def json(self): return [{"ok": True}]
    monkeypatch.setattr(a._client, "request", lambda method, path, **kw: _ReqResp(codes.pop(0)))
    out = a._get("roadmap", {})
    assert out == [{"ok": True}]            # got the retried 200
    assert len(exchanges) == 2              # the 401 forced exactly one re-exchange
