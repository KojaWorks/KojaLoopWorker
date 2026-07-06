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
import os
import sys
from pathlib import Path

from . import dashboard, filelog
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


def main(argv: list[str] | None = None) -> int:
    load_dotenv()
    p = argparse.ArgumentParser(prog="loopworker", description=__doc__)
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
    args = p.parse_args(argv)

    filelog.configure(args.log_file)
    return _run_single(args) if args.project else _run_host(args)


if __name__ == "__main__":
    raise SystemExit(main())
