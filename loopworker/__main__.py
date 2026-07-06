"""CLI entrypoint.

Two modes:
  * Host mode (default): `loopworker` reads ~/.loopworker/config.toml and serves EVERY
    project in the shared backlog whose worker_manager is this host's — cloning each on
    demand. This is the per-host Manager.
  * Single-project mode: `loopworker --project <dir>` serves just that one working copy
    (its .loopworker/manifest.toml is the source of truth). Handy for local testing.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import __version__, dashboard, filelog, readiness
from .config import HostConfig, Manifest
from .host import HostManager
from .manager import Manager


def load_dotenv() -> None:
    """Load KEY=VALUE pairs from a `.env` into os.environ so `loopworker` just works
    after `cp .env.example .env` (the README's promise). Looks in the CWD and the
    repo root; a real env var already set always wins (so `PATCH_PAT=… loopworker`
    still overrides). A tiny parser — no dependency, no interpolation/export syntax."""
    for path in (Path.cwd() / ".env", Path(__file__).resolve().parent.parent / ".env"):
        if not path.is_file():
            continue
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            if key and key not in os.environ:
                os.environ[key] = val.strip().strip('"').strip("'")


def _run_single(args) -> int:
    try:
        manifest = Manifest.load(args.project)
    except (FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.slots is not None:
        manifest.slots = args.slots
    manager = Manager(
        manifest,
        poll_interval=args.poll_interval,
        reconcile_interval=args.reconcile_interval,
        grace_seconds=args.grace,
        base_port=args.base_port,
        state_dir=args.state_dir,
    )
    # A real unattended run: fail fast on a dead claude login. No notify_command wiring
    # here (that config lives on HostConfig, host-mode only) — single-project mode
    # still pauses dispatch on a dead login, it just doesn't push an alert about it.
    manager.auth.enabled = True
    manager.log(f"file log: {filelog.path()}")
    if not args.no_dashboard:
        dashboard.serve(manager.snapshot, port=args.dashboard_port)
        manager.log(f"dashboard at http://127.0.0.1:{args.dashboard_port}")
    if args.once:
        manager.pool.build()
        manager.tick()
        return 0
    manager.run()
    return 0


def _run_host(args) -> int:
    try:
        host = HostConfig.load(args.config)
    except (FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    manager = HostManager(
        host,
        poll_interval=args.poll_interval,
        reconcile_interval=args.reconcile_interval,
        grace_seconds=args.grace,
        state_dir=args.state_dir,
    )
    manager.log(f"file log: {filelog.path()}")
    if not args.no_dashboard:
        dashboard.serve(manager.snapshot, port=args.dashboard_port)
        manager.log(f"dashboard at http://127.0.0.1:{args.dashboard_port}")
    if args.once:
        manager.discover()
        manager.build()
        manager.tick()
        return 0
    manager.run()
    return 0


def _cmd_doctor(argv: list[str]) -> int:
    """Host-prerequisite sweep — the operator's 'why won't it start' answer. Runs standalone
    (no running Manager needed); exit 0 iff every check passes. `--json` is what the Mac
    readiness panel consumes."""
    ap = argparse.ArgumentParser(prog="loopworker doctor")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--config", type=Path, default=None, help="host config path (default ~/.loopworker/config.toml)")
    a = ap.parse_args(argv)
    try:
        config = HostConfig.load(a.config)
    except (FileNotFoundError, ValueError):
        config = None  # no host config yet — checks still run; backlog reports it
    checks = readiness.check_all(config)
    all_ok = all(c.ok for c in checks)
    if a.json:
        print(json.dumps({"ok": all_ok, "checks": [c.as_dict() for c in checks]}, indent=2))
    else:
        for c in checks:
            print(f"[{'OK  ' if c.ok else 'FAIL'}] {c.name:8} {c.detail}")
            if not c.ok and c.remedy:
                print(f"            -> {c.remedy}")
        print("\nready" if all_ok else "\nnot ready — fix the FAIL lines above", file=sys.stderr)
    return 0 if all_ok else 1


def _cmd_status(argv: list[str]) -> int:
    """Pretty-print a running Manager's /json in the terminal — the Linux at-a-glance."""
    ap = argparse.ArgumentParser(prog="loopworker status")
    ap.add_argument("--port", type=int, default=8787, help="dashboard port (default 8787)")
    ap.add_argument("--json", action="store_true", help="dump the raw snapshot")
    a = ap.parse_args(argv)
    import httpx
    try:
        snap = httpx.get(f"http://127.0.0.1:{a.port}/json", timeout=5.0).json()
    except Exception as e:
        print(f"no running Manager on 127.0.0.1:{a.port} ({e})", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(snap, indent=2))
        return 0
    who = snap.get("worker_manager") or snap.get("project", "?")
    paused = "  [PAUSED]" if snap.get("paused") else ""
    print(f"LoopWorker · {who}{paused} · started {snap.get('started_at')} · poll {snap.get('poll_interval')}s")
    projects = snap.get("projects") or [snap]  # host: list; single: wrap the top level
    for p in projects:
        if "projects" in snap:
            print(f"\n{p.get('project')} · {'hot' if p.get('hot') else 'cold'}")
        for s in p.get("slots", []):
            card = f"~{s['card']}" if s.get("card") else "—"
            print(f"  slot {s['index']}: {s['state']:6} {card:6} {s.get('activity') or ''}")
    return 0


def main(argv: list[str] | None = None) -> int:
    raw = sys.argv[1:] if argv is None else argv
    # Load .env before anything dispatches so `doctor`'s claude/backlog checks see the same
    # secrets the Manager runs with (CLAUDE_CODE_OAUTH_TOKEN, PATCH_PAT) — otherwise doctor
    # reports a false "not logged in" the Manager wouldn't actually hit.
    load_dotenv()
    if raw and raw[0] == "doctor":
        return _cmd_doctor(raw[1:])
    if raw and raw[0] == "status":
        return _cmd_status(raw[1:])
    p = argparse.ArgumentParser(prog="loopworker", description=__doc__)
    p.add_argument("--version", action="version", version=f"loopworker {__version__}")
    p.add_argument("--project", help="single-project mode: path to a LoopWorker working copy")
    p.add_argument("--config", type=Path, default=None, help="host-mode config path (default ~/.loopworker/config.toml)")
    p.add_argument("--poll-interval", type=int, default=300, help="seconds between spawning new workers (default 300)")
    p.add_argument("--reconcile-interval", type=int, default=15, help="seconds between reconciles — reap/dashboard freshness (default 15)")
    p.add_argument("--grace", type=int, default=120, help="seconds to wait before reaping a finished worker")
    p.add_argument("--slots", type=int, default=None, help="single-project: override manifest slot count")
    p.add_argument("--base-port", type=int, default=54400, help="single-project: first slot's stack port")
    p.add_argument("--dashboard-port", type=int, default=8787)
    p.add_argument("--no-dashboard", action="store_true")
    p.add_argument("--state-dir", type=Path, default=None)
    p.add_argument("--log-file", type=Path, default=Path("state") / "manager.log",
                   help="rotating on-disk log (default state/manager.log); the durable record of "
                        "the Manager's decisions, redacted. Also on stdout + the dashboard.")
    p.add_argument("--once", action="store_true", help="run a single tick then exit (after building the pool)")
    args = p.parse_args(raw)

    filelog.configure(args.log_file)
    return _run_single(args) if args.project else _run_host(args)


if __name__ == "__main__":
    raise SystemExit(main())
