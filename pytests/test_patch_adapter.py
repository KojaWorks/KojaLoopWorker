"""Mock-based tests for the Patch adapter's mapping and selection logic — no network.
The PostgREST verbs (_get/_patch/_post) are stubbed; everything above them is real."""
import base64
import json
from pathlib import Path

import httpx
import pytest

from loopworker.config import (BacklogConfig, BriefConfig, Manifest,
                               ScriptsConfig, WorkerConfig)
from loopworker.models import Card, CardStatus, Worker
from loopworker.backlog.patch import PatchAdapter


def _fake_jwt(sub="owner"):
    """A JWT-shaped token carrying `sub` — the adapter reads the owner uid from it."""
    payload = base64.urlsafe_b64encode(json.dumps({"sub": sub}).encode()).rstrip(b"=").decode()
    return f"h.{payload}.s"


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
    monkeypatch.setattr(PatchAdapter, "_ensure_token", lambda self, force=False, retry=False: None)
    a = PatchAdapter(_manifest())
    a._owner_uid = "owner"       # normally set from the exchanged JWT; stub it for the gate
    return a


def _row(num, status="Backlog", **kw):
    base = {"id": f"u{num}", "id_2": num, "title": f"card {num}", "status": status,
            "priority": num, "area": [], "epic": None, "blocked_by": None,
            "assignee": None, "solved_in_pr": None, "created_by": "owner"}
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


def test_card_model_column_mapped(adapter):
    c = adapter._to_card(_row(1, model="fable"))
    assert c.model == "fable"
    c2 = adapter._to_card(_row(2))
    assert c2.model is None                      # missing column -> None (project default applies)
    c3 = adapter._to_card(_row(3, model=""))
    assert c3.model is None                      # blank select value -> None, not ""


def test_list_workable_filters_and_sorts(adapter, monkeypatch):
    rows = [
        _row(1, priority=10),                                  # workable
        _row(2, priority=99, area=["epic"]),                   # epic -> skip
        _row(3, priority=50, assignee="w1"),                   # claimed -> skip
        _row(4, priority=80, status="In progress"),            # not backlog -> skip
        _row(5, priority=70, blocked_by=["u-unshipped"]),      # blocker not Shipped -> skip
        _row(9, priority=1, status="Shipped"),                 # a shipped card (blocker for 6)
        _row(6, priority=60, blocked_by=["u9"]),               # blocker shipped -> workable
        _row(8, priority=10),                                  # ties with 1 -> older (1) first
        _row(7, priority=None),                                # unranked -> 0, sinks to bottom
    ]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    workable = adapter.list_workable()
    nums = [c.num for c in workable]
    # 6 (60) > {1,8 tie at 10, oldest first} > 7 (unranked -> 0, last)
    assert nums == [6, 1, 8, 7]


def test_list_projects_maps_rows(adapter, monkeypatch):
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"        # registered (host.run registers before discover)
    rows = [
        {"id": "p1", "name": "Patch", "repo": "git@x", "default_branch": "main",
         "slots": 3, "hot": True, "brief_ref": None, "weight": 2, "model": "opus",
         "manager": "m1", "created_by": "owner"},
        {"id": "p2", "name": "GitZ", "repo": None, "default_branch": None,
         "slots": None, "hot": False, "brief_ref": "u", "manager": "m1", "created_by": "owner"},
        {"id": "p3", "name": "Blank", "repo": None, "default_branch": None,
         "slots": None, "hot": False, "brief_ref": None, "model": "", "manager": "m1",
         "created_by": "owner"},
    ]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows if table == adapter.projects else [])
    ps = adapter.list_projects()
    assert [p.name for p in ps] == ["Patch", "GitZ", "Blank"]
    assert ps[0].hot is True and ps[0].slots == 3
    assert ps[1].default_branch == "main" and ps[1].hot is False  # null default_branch -> "main"
    assert ps[0].weight == 2.0                                   # explicit weight parsed
    assert ps[1].weight == 1.0                                   # missing column -> default
    assert ps[0].model == "opus" and ps[1].model is None         # missing column -> None default
    assert ps[2].model is None                                   # blank select value -> None, not ""


def test_list_projects_tolerates_relation_cardinality(adapter, monkeypatch):
    # projects.manager may be a single link (scalar id) or a to-many (array of ids). The Manager
    # must serve a project whenever OUR id is among the link(s) — so several hosts can share one
    # project — and must keep working across an in-place cardinality flip (~de489ec1).
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"

    def served(manager_value):
        rows = [{"id": "p1", "name": "P", "repo": "git@x", "manager": manager_value,
                 "created_by": "owner"}]
        monkeypatch.setattr(adapter, "_get",
                            lambda table, params: rows if table == adapter.projects else [])
        return [p.name for p in adapter.list_projects()]

    assert served("m1") == ["P"]              # to-one: scalar, ours
    assert served("m2") == []                 # to-one: scalar, another host's
    assert served(["m1"]) == ["P"]            # to-many: single-element array, ours
    assert served(["m2", "m1"]) == ["P"]      # to-many: ours among several
    assert served(["m2", "m3"]) == []         # to-many: not ours
    assert served([]) == []                   # to-many: unassigned
    assert served(None) == []                 # relation unset


def test_gate_drops_untrusted_author_card(adapter, monkeypatch):
    # A card by someone outside the trusted set is never workable, even if otherwise ready.
    rows = [_row(1, created_by="owner"), _row(2, created_by="mallory")]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert [c.num for c in adapter.list_workable()] == [1]


def test_gate_trusts_local_override_author(monkeypatch):
    # trusted_authors from LOCAL config (the manifest, in single-project mode) widens the gate.
    monkeypatch.setenv("PATCH_PAT", "pat_test")
    monkeypatch.setattr(PatchAdapter, "_ensure_token", lambda self, force=False, retry=False: None)
    m = _manifest()
    m.trusted_authors = ["mallory"]
    a = PatchAdapter(m)
    a._owner_uid = "owner"
    rows = [_row(1, created_by="owner"), _row(2, created_by="mallory"), _row(3, created_by="stranger")]
    monkeypatch.setattr(a, "_get", lambda table, params: rows)
    assert sorted(c.num for c in a.list_workable()) == [1, 2]  # stranger still dropped


def test_gate_drops_card_with_missing_author(adapter, monkeypatch):
    # No created_by (unexpected) is untrusted, not a free pass — fail closed.
    rows = [_row(1)]
    rows[0].pop("created_by")
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert adapter.list_workable() == []


def test_gate_drops_untrusted_project(adapter, monkeypatch):
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"
    rows = [
        {"id": "p1", "name": "Mine", "repo": "git@x", "manager": "m1", "created_by": "owner"},
        {"id": "p2", "name": "Theirs", "repo": "git@y", "manager": "m1", "created_by": "mallory"},
    ]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert [p.name for p in adapter.list_projects()] == ["Mine"]


def test_gate_drops_project_with_missing_author(adapter, monkeypatch):
    # The higher-stakes path (a projects row runs foreign provision scripts): no created_by
    # is untrusted, not a free pass.
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"
    rows = [{"id": "p1", "name": "NoAuthor", "repo": "git@x", "manager": "m1"}]  # created_by absent
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert adapter.list_projects() == []


def test_gate_untrusted_project_scopes_out_its_cards(adapter, monkeypatch):
    # A card tagged to an untrusted-authored project is out of scope (project id dropped
    # from the served set), even if the card itself is owner-authored.
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"
    roadmap = [_row(1, project="p-mine"), _row(2, project="p-theirs")]
    def fake_get(table, params):
        if table == adapter.projects:
            return [{"id": "p-mine", "manager": "m1", "created_by": "owner"},
                    {"id": "p-theirs", "manager": "m1", "created_by": "mallory"}]
        return roadmap
    monkeypatch.setattr(adapter, "_get", fake_get)
    assert [c.num for c in adapter.list_workable()] == [1]


def test_gate_logs_each_gated_row_once(adapter, monkeypatch):
    logs = []
    adapter._log = logs.append
    rows = [_row(1, created_by="mallory")]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    adapter.list_workable()
    adapter.list_workable()                      # second poll, same gated card
    assert sum("~1" in m for m in logs) == 1     # logged once, not per poll


def test_jwt_sub_decodes_and_rejects_bad_tokens():
    from loopworker.backlog.patch import _jwt_sub
    assert _jwt_sub(_fake_jwt("owner-uid")) == "owner-uid"
    with pytest.raises(RuntimeError, match="decode owner uid"):
        _jwt_sub("not-a-jwt")
    with pytest.raises(RuntimeError, match="no `sub`"):
        _jwt_sub(_fake_jwt(""))                   # empty sub -> refuse
    # a payload that decodes to a non-object (number/list/string) has no sub -> refuse cleanly,
    # not a raw AttributeError
    nonobj = base64.urlsafe_b64encode(b"123").rstrip(b"=").decode()
    with pytest.raises(RuntimeError, match="no `sub`"):
        _jwt_sub(f"h.{nonobj}.s")


def test_no_project_filter_when_worker_manager_unset(adapter, monkeypatch):
    # Back-compat: an empty worker_manager serves every project (no projects lookup).
    rows = [_row(1, project="p-other")]
    monkeypatch.setattr(adapter, "_get", lambda table, params: rows)
    assert [c.num for c in adapter.list_workable()] == [1]


def test_project_filter_scopes_to_served(adapter, monkeypatch):
    adapter.worker_manager = "miquon"
    adapter._manager_id = "m1"
    roadmap = [
        _row(1, project="p-patch"),   # mine -> keep
        _row(2, project="p-gitz"),    # another manager's -> skip
        _row(3, project=None),        # untagged; sole served project -> adopted
    ]
    def fake_get(table, params):
        return ([{"id": "p-patch", "manager": "m1", "created_by": "owner"}]
                if table == adapter.projects else roadmap)
    monkeypatch.setattr(adapter, "_get", fake_get)
    assert sorted(c.num for c in adapter.list_workable()) == [1, 3]


def test_untagged_card_skipped_when_serving_multiple(adapter, monkeypatch):
    adapter.worker_manager = "multi"
    adapter._manager_id = "m1"
    roadmap = [_row(1, project=None), _row(2, project="p-a")]
    def fake_get(table, params):
        return ([{"id": "p-a", "manager": "m1", "created_by": "owner"},
                 {"id": "p-b", "manager": "m1", "created_by": "owner"}]
                if table == adapter.projects else roadmap)
    monkeypatch.setattr(adapter, "_get", fake_get)
    assert [c.num for c in adapter.list_workable()] == [2]  # untagged is ambiguous -> not picked


def test_claim_returns_true_when_row_updated(adapter, monkeypatch):
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: [_row(1, status="In progress")])
    assert adapter.claim(Card("u1", 1, "t", CardStatus.BACKLOG, 1), Worker("w1", "ada")) is True


def test_claim_returns_false_when_no_row(adapter, monkeypatch):
    # atomic claim lost: assignee=is.null filter matched nothing -> empty list
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: [])
    assert adapter.claim(Card("u1", 1, "t", CardStatus.BACKLOG, 1), Worker("w1", "ada")) is False


def test_register_manager_updates_existing(adapter, monkeypatch):
    calls = {}
    monkeypatch.setattr(adapter, "_get", lambda t, p: [{"id": "m1"}])
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: calls.update(table=t, params=p, body=b) or [{"id": "m1"}])
    monkeypatch.setattr(adapter, "_post", lambda t, b: pytest.fail("existing row -> update, not insert"))
    adapter.register_manager("miquon", "v0.1.0 · 3 project(s) · 1/8 slot(s) busy")
    assert calls["table"] == adapter.managers
    assert calls["params"] == {"id": "eq.m1"}
    assert calls["body"]["summary"].startswith("v0.1.0") and "last_active" in calls["body"]


def test_register_manager_inserts_when_absent(adapter, monkeypatch):
    calls = {}
    monkeypatch.setattr(adapter, "_get", lambda t, p: [])
    monkeypatch.setattr(adapter, "_post", lambda t, b: calls.update(table=t, body=b) or [{"id": "m2"}])
    monkeypatch.setattr(adapter, "_patch", lambda t, p, b: pytest.fail("no row -> insert, not update"))
    adapter.register_manager("raheth", "summary")
    assert calls["table"] == adapter.managers
    assert calls["body"]["name"] == "raheth" and "last_active" in calls["body"]


def test_register_worker_links_to_manager(adapter, monkeypatch):
    adapter._manager_id = "mid-2"
    captured = {}
    monkeypatch.setattr(adapter, "_get", lambda t, p: [])          # no existing worker row
    monkeypatch.setattr(adapter, "_post", lambda t, b: captured.update(b) or [{"id": "w1"}])
    adapter.register_worker("ada")
    assert captured["manager"] == "mid-2"                          # worker linked to its manager


def test_served_rows_filters_by_manager_relation(adapter):
    # Client-side membership, so it holds whether `manager` is a single link OR a to-many array.
    adapter.worker_manager = "miquon"
    adapter._manager_id = "mid-1"
    rows = [{"id": "a", "manager": "mid-1"},      # to-one, ours
            {"id": "b", "manager": "other"},      # to-one, another host's
            {"id": "c", "manager": ["x", "mid-1"]},  # to-many, ours among several
            {"id": "d", "manager": []},           # to-many, unassigned
            {"id": "e", "manager": None}]         # unset
    assert [r["id"] for r in adapter._served_rows(rows)] == ["a", "c"]


def test_served_rows_raises_without_manager_row(adapter, monkeypatch):
    # No loop_managers row -> can't determine our projects. Raise (the host registers before
    # discover); NEVER serve everything, which a downstream reconcile could misread as "serve all".
    adapter.worker_manager = "miquon"
    adapter._manager_id = None
    monkeypatch.setattr(adapter, "_get", lambda t, p: [])   # manager-id lookup finds nothing
    with pytest.raises(RuntimeError):
        adapter._served_rows([{"id": "a", "manager": "m1"}])


def test_served_rows_passes_all_when_worker_manager_unset(adapter):
    adapter.worker_manager = ""
    rows = [{"id": "a", "manager": "whatever"}, {"id": "b"}]
    assert adapter._served_rows(rows) == rows   # single-project legacy: no host filter


def test_brief_points_worker_at_patch_page(adapter):
    brief = adapter.get_brief()
    assert "cfacaea7-59e9-4f40-8bba-44c10137a48e" in brief
    assert "get_page" in brief


class _ExResp:
    def __init__(self, sub="owner"):
        self.status_code = 200
        self._token = _fake_jwt(sub)
    def raise_for_status(self): pass
    def json(self): return {"access_token": self._token, "expires_at": 9_999_999_999}


def test_exchange_sets_bearer_and_caches(monkeypatch):
    # __init__ exchanges the PAT once; a far-future expiry means no re-exchange.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    posts = []
    def fake_post(url, json, headers, timeout):
        posts.append((url, json["token"], headers.get("apikey")))
        return _ExResp("owner-1")
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post", fake_post)
    a = PatchAdapter(_manifest())
    assert a._client.headers["Authorization"] == f"Bearer {_fake_jwt('owner-1')}"
    assert a._owner_uid == "owner-1"        # owner uid read from the exchanged JWT's sub
    assert posts == [("https://api.patch/functions/v1/pat-exchange", "pat_abc", "anon-test")]
    a._ensure_token()                       # cached -> no second exchange
    assert len(posts) == 1


class _Resp:
    """A scripted pat-exchange response for the retry tests."""
    def __init__(self, code, sub="owner"):
        self.status_code = code
        self._token = _fake_jwt(sub)
    def raise_for_status(self):
        if self.status_code >= 400:
            raise httpx.HTTPStatusError("err", request=None, response=None)
    def json(self):
        return {"access_token": self._token, "expires_at": 9_999_999_999}


def test_exchange_retries_transient_5xx_then_succeeds(monkeypatch):
    # prod mid-redeploy: 502, 502, then 200 -> the adapter waits it out and starts.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    codes, posts = [502, 502, 200], []
    def fake_post(url, json, headers, timeout):
        code = codes.pop(0); posts.append(code); return _Resp(code)
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post", fake_post)
    sleeps = []
    monkeypatch.setattr("loopworker.backlog.patch.time.sleep", lambda s: sleeps.append(s))
    a = PatchAdapter(_manifest())
    assert a._owner_uid == "owner"
    assert posts == [502, 502, 200]        # retried through both 5xx windows
    assert sleeps == [10.0, 20.0]          # capped exponential backoff between attempts


def test_exchange_retries_connect_error(monkeypatch):
    # A connect failure (Kong stale upstream) is transient too, not fatal.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    seq = [httpx.ConnectError("boom"), _Resp(200)]
    def fake_post(url, json, headers, timeout):
        item = seq.pop(0)
        if isinstance(item, Exception):
            raise item
        return item
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post", fake_post)
    monkeypatch.setattr("loopworker.backlog.patch.time.sleep", lambda s: None)
    a = PatchAdapter(_manifest())
    assert a._owner_uid == "owner"


def test_exchange_fails_fast_on_auth(monkeypatch):
    # A genuine bad/revoked PAT (401) must NOT be retried — surface immediately.
    monkeypatch.setenv("PATCH_PAT", "pat_bad")
    posts = []
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post",
                        lambda url, json, headers, timeout: posts.append(1) or _Resp(401))
    sleeps = []
    monkeypatch.setattr("loopworker.backlog.patch.time.sleep", lambda s: sleeps.append(s))
    with pytest.raises(RuntimeError, match="rejected PATCH_PAT"):
        PatchAdapter(_manifest())
    assert len(posts) == 1 and sleeps == []      # one attempt, no backoff


def test_exchange_gives_up_and_notifies_after_budget(monkeypatch):
    # A sustained outage past the retry budget gives up with a clear error and alerts.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post",
                        lambda url, json, headers, timeout: _Resp(503))
    monkeypatch.setattr("loopworker.backlog.patch.time.sleep", lambda s: None)
    alerts = []
    with pytest.raises(RuntimeError, match="giving up"):
        PatchAdapter(_manifest(), retry_budget_seconds=25,
                     notify=lambda key, msg: alerts.append((key, msg)))
    assert alerts and alerts[0][0] == "patch-unreachable"


def test_runtime_refresh_fails_fast_not_retried(monkeypatch):
    # A mid-run token refresh hitting a 5xx must surface at once — the retry loop is
    # startup-only, so the single-threaded host isn't blocked for minutes on a refresh.
    monkeypatch.setenv("PATCH_PAT", "pat_abc")
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post",
                        lambda url, json, headers, timeout: _Resp(200))
    a = PatchAdapter(_manifest())                    # startup exchange ok
    sleeps = []
    monkeypatch.setattr("loopworker.backlog.patch.time.sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr("loopworker.backlog.patch.httpx.post",
                        lambda url, json, headers, timeout: _Resp(503))
    a._access_exp = 0.0                              # force a re-exchange on next request
    with pytest.raises(RuntimeError, match="unreachable during PAT exchange"):
        a._get("roadmap", {})
    assert sleeps == []                              # no backoff on the runtime path


def test_card_links_empty_without_config(adapter):
    # app_base/roadmap_page_id unset -> the dashboard gets no links (plain ~NNN).
    adapter._to_card(_row(1))
    assert adapter.card_links() == {}


def test_card_links_built_from_reads(monkeypatch):
    monkeypatch.setenv("PATCH_PAT", "pat_test")
    monkeypatch.setattr(PatchAdapter, "_ensure_token", lambda self, force=False, retry=False: None)
    m = _manifest()
    m.backlog.options.update({"app_base": "https://patch.example/", "roadmap_page_id": "PAGE"})
    a = PatchAdapter(m)
    a._to_card(_row(772))                        # every read remembers num -> uuid
    a._to_card(_row(801))
    links = a.card_links()
    # trailing slash on app_base is trimmed; row uuid comes from the card's id
    assert links["772"] == "https://patch.example/app/PAGE?row=u772&rowpage=1"
    assert links["801"].endswith("row=u801&rowpage=1")


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


def test_name_for_slot_varies_by_project():
    from loopworker.names import name_for_slot, _NAMES
    n = len(_NAMES)
    # within a project, slots get distinct names (the uniqueness invariant that keeps each
    # slot's loop_workers row stable + reused). Past 2*n to exercise the offset+wrap
    # boundary (index >= n), where the cycle suffix must disambiguate the wrapped base.
    for proj in ("", "patch-", "kojaloopworker-"):
        assert len({name_for_slot(i, proj) for i in range(2 * n + 3)}) == 2 * n + 3
    # slot 0 reads differently for two different projects (the whole point of the card)
    assert name_for_slot(0, "patch-") != name_for_slot(0, "kojaloopworker-")
    # stable hash: same (project, slot) is identical across calls / a restart
    assert name_for_slot(3, "patch-") == name_for_slot(3, "patch-")


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
