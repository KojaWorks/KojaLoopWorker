"""Worker names. Names are cosmetic — the claim's identity is the worker row id.

One STABLE name per slot (slot 0 = ada, slot 1 = babbage, …), reused across cards:
the worker row is upserted per name, so the loop_workers table stays N rows (one per
slot) instead of growing by one every card."""
from __future__ import annotations

_NAMES = [
    "ada", "babbage", "turing", "hopper", "lovelace", "dijkstra", "knuth", "ritchie",
    "thompson", "kay", "engelbart", "liskov", "backus", "hamilton", "perlis", "wozniak",
    "torvalds", "stallman", "minsky", "shannon", "boole", "church", "curry", "hoare",
]


def name_for_slot(index: int) -> str:
    """The stable Worker name for a slot. Wraps the pool for pools larger than it."""
    base = _NAMES[index % len(_NAMES)]
    cycle = index // len(_NAMES)
    return base if cycle == 0 else f"{base}{cycle + 1}"
