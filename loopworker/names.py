"""Worker names. Names are cosmetic — the claim's identity is the worker row id.

One STABLE name per slot (slot 0 = ada, slot 1 = babbage, …), reused across cards:
the worker row is upserted per name, so the loop_workers table stays N rows (one per
slot) instead of growing by one every card.

A per-project offset rotates the starting name so two projects' slot 0 don't both read
"ada" in the dashboard/loop_workers. The offset is ADDED to the slot index (not a direct
hash of project+slot), so within a project consecutive slots still get distinct names —
that per-(project,slot) uniqueness is what keeps each slot's worker row stable and reused."""
from __future__ import annotations

import hashlib

_NAMES = [
    "ada", "babbage", "turing", "hopper", "lovelace", "dijkstra", "knuth", "ritchie",
    "thompson", "kay", "engelbart", "liskov", "backus", "hamilton", "perlis", "wozniak",
    "torvalds", "stallman", "minsky", "shannon", "boole", "church", "curry", "hoare",
]


def name_for_slot(index: int, project: str = "") -> str:
    """The stable Worker name for a slot, rotated by a per-project offset.

    Wraps the pool for pools larger than it. `project` (a slug/prefix) shifts the
    starting name so different projects read distinctly; empty keeps the plain ada,
    babbage, … order. Uses a stable hash (not builtin hash(), which is per-process
    salted) so the name survives a restart."""
    offset = 0
    if project:
        offset = int.from_bytes(hashlib.sha1(project.encode()).digest()[:4], "big") % len(_NAMES)
    n = offset + index
    base = _NAMES[n % len(_NAMES)]
    cycle = index // len(_NAMES)
    return base if cycle == 0 else f"{base}{cycle + 1}"
