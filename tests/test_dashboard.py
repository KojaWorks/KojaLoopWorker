"""The dashboard's ~NNN linkifier: resolvable card refs become anchors, unresolved
ones stay plain (escaped) text, and no rendering path trusts raw log/card content."""
import json

from loopworker import __version__
from loopworker.dashboard import (
    CONTRACT_VERSION,
    _health,
    _linkify,
    _render,
    _render_host,
    _response,
)

_LINKS = {"772": "https://patch.example/app/PAGE?row=u772&rowpage=1"}


def test_linkify_wraps_known_ref():
    out = _linkify("slot 1 ~772: reclaiming card", _LINKS)
    # & in the query string is escaped inside the href; the ~772 label is preserved
    assert ('<a href="https://patch.example/app/PAGE?row=u772&amp;rowpage=1" '
            'target="_blank" rel="noopener noreferrer">~772</a>') in out
    assert "reclaiming card" in out


def test_linkify_leaves_unknown_ref_plain():
    assert _linkify("lost claim for ~999 — skipping", _LINKS) == "lost claim for ~999 — skipping"


def test_linkify_escapes_html():
    # a log line with markup must not inject into the page; escape first, then linkify
    out = _linkify("<script> ~772", _LINKS)
    assert out.startswith("&lt;script&gt; ")
    assert ">~772</a>" in out


def _slot(card):
    return {"index": 0, "state": "busy", "activity": f"running ~{card} (ada)", "thinking": "",
            "port": None, "model": "opus", "card": card, "session": "s", "started_at": "t"}


def test_render_links_activity_column():
    # the Manager-authored activity string ("running ~772 (ada)") is linkified too
    out = _render(_single_snap())
    assert 'rel="noopener noreferrer">~772</a> (ada)' in out


def _single_snap():
    return {"project": "demo", "paused": False, "started_at": "t", "poll_interval": 30,
            "slots": [_slot(772)], "log": ["spawned on ~772 (ada)"], "card_links": _LINKS}


def test_render_links_card_column_and_log():
    out = _render(_single_snap())
    # linkified in the activity cell, the card cell, and the log line
    assert out.count("row=u772") == 3
    assert ">~772</a>" in out


def test_render_plain_when_no_links():
    snap = _single_snap()
    snap["card_links"] = {}
    out = _render(snap)
    assert "<a href" not in out
    assert "~772" in out                              # still shown, just not a link


def test_render_host_links_slots_and_log():
    snap = {"worker_manager": "miquon", "started_at": "t", "paused": False,
            "poll_interval": 30, "max_slots": 4, "max_concurrent_workers": 4,
            "busy_total": 1, "log": ["slot 0 ~772: reap grace started"],
            "projects": [{"project": "Patch", "hot": True, "paused": False,
                          "slots": [_slot(772)]}],
            "card_links": _LINKS}
    out = _render_host(snap)
    # slot activity cell + slot card cell + host log line
    assert out.count("row=u772") == 3


# --- status contract: /json version stamps + /health compact summary ---------------


def _host_snap():
    return {"worker_manager": "miquon", "started_at": "t", "paused": True,
            "poll_interval": 30, "busy_total": 1,
            "projects": [{"project": "Patch", "hot": True, "slots": [_slot(772), _idle_slot()]}],
            "log": [], "card_links": {}}


def _idle_slot():
    return {"index": 1, "state": "idle", "activity": "", "thinking": "", "port": None,
            "model": None, "card": None, "session": None, "started_at": None}


def test_json_carries_version_stamps():
    body, ctype = _response("/json", _single_snap())
    assert ctype == "application/json"
    payload = json.loads(body)
    assert payload["contract_version"] == CONTRACT_VERSION
    assert payload["loopworker_version"] == __version__
    assert payload["project"] == "demo"          # original snapshot preserved


def test_health_host_shape():
    body, ctype = _response("/health", _host_snap())
    assert ctype == "application/json"
    h = json.loads(body)
    assert h["mode"] == "host" and h["worker_manager"] == "miquon"
    assert h["paused"] is True and h["busy"] == 1 and h["slots"] == 2
    assert h["contract_version"] == CONTRACT_VERSION and h["loopworker_version"] == __version__


def test_health_single_shape_counts_busy_from_slots():
    h = _health(_single_snap())                  # single-project snapshot, one busy slot
    assert h["mode"] == "single" and h["worker_manager"] == "demo"
    assert h["slots"] == 1 and h["busy"] == 1


def test_unknown_path_renders_html():
    body, ctype = _response("/", _single_snap())
    assert ctype.startswith("text/html")
    assert b"LoopWorker" in body
