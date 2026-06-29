"""Worker name generation. The Manager names each Worker (the old in-session loop had
workers name themselves). Names are cosmetic — the claim's identity is the worker row id."""
from __future__ import annotations

import random

_NAMES = [
    "ada", "babbage", "turing", "hopper", "lovelace", "dijkstra", "knuth", "ritchie",
    "thompson", "kay", "engelbart", "liskov", "backus", "hamilton", "perlis", "wozniak",
    "torvalds", "stallman", "minsky", "shannon", "boole", "church", "curry", "hoare",
]


def pick_name(taken: set[str]) -> str:
    free = [n for n in _NAMES if n not in taken]
    if free:
        return random.choice(free)
    # pool exhausted — suffix a number
    base = random.choice(_NAMES)
    i = 2
    while f"{base}{i}" in taken:
        i += 1
    return f"{base}{i}"
