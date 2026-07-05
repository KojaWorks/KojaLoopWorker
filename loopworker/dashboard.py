"""A tiny local HTTP status page. The Manager is already a long-lived process, so
serving its in-memory snapshot is nearly free and gives real-time visibility."""
from __future__ import annotations

import html
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

SnapshotProvider = Callable[[], dict]

_CARD_REF = re.compile(r"~(\d+)")


def _linkify(text: str, card_links: dict[str, str]) -> str:
    """HTML-escape `text`, then turn each ~NNN whose card resolves in `card_links` into
    an anchor. Unresolved refs stay plain text (no broken links)."""
    def repl(m: re.Match) -> str:
        url = card_links.get(m.group(1))
        if not url:
            return m.group(0)
        return (f'<a href="{html.escape(url, quote=True)}" target="_blank"'
                f' rel="noopener noreferrer">{m.group(0)}</a>')
    return _CARD_REF.sub(repl, html.escape(text))


def _slots_table(slots: list[dict], card_links: dict[str, str]) -> str:
    rows = "".join(
        f"<tr><td>{s['index']}</td><td>{s['state']}</td>"
        f"<td>{_linkify(s['activity'], card_links) if s.get('activity') else '—'}</td>"
        f"<td>{s.get('port') or '—'}</td>"
        f"<td>{html.escape(s.get('model') or '—')}</td>"
        f"<td>{_linkify('~' + str(s['card']), card_links) if s['card'] else '—'}</td>"
        f"<td>{html.escape(s['session'] or '—')}</td>"
        f"<td>{s['started_at'] or '—'}</td>"
        f"<td class=thinking>{html.escape(s.get('thinking') or '—')}</td></tr>"
        for s in slots
    )
    return ("<table><tr><th>slot</th><th>state</th><th>activity</th><th>port</th>"
            "<th>model</th><th>card</th><th>session</th><th>started</th><th>thinking</th></tr>"
            f"{rows}</table>")


def _render_host(snap: dict) -> str:
    card_links = snap.get("card_links") or {}
    paused = " · <b style='color:#c0392b'>PAUSED</b>" if snap["paused"] else ""
    sections = "".join(
        f"<h3>{html.escape(p['project'])} · {'hot' if p.get('hot') else 'cold'}"
        f"{' · PAUSED' if p.get('paused') else ''}</h3>{_slots_table(p['slots'], card_links)}"
        for p in snap["projects"]
    )
    log = "".join(f"<div>{_linkify(line, card_links)}</div>" for line in reversed(snap["log"]))
    return f"""<!doctype html><meta charset=utf-8>
<meta http-equiv=refresh content=5>
<title>LoopWorker · host {html.escape(snap['worker_manager'])}</title>
<style>
 body{{font:13px ui-monospace,Menlo,monospace;margin:2rem;color:#222}}
 table{{border-collapse:collapse;margin:.5rem 0 1.5rem}}
 td,th{{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}}
 .log{{background:#f6f6f6;padding:.6rem;max-height:50vh;overflow:auto;white-space:pre-wrap}}
 .thinking{{max-width:34rem;color:#555;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
</style>
<h2>LoopWorker · host {html.escape(snap['worker_manager'])}{paused}</h2>
<div>started {snap['started_at']} · poll every {snap['poll_interval']}s · max {snap['max_slots']} slot(s)</div>
{sections}
<h3>host log</h3><div class=log>{log}</div>
"""


def _render(snap: dict) -> str:
    if "projects" in snap:
        return _render_host(snap)
    card_links = snap.get("card_links") or {}
    log = "".join(f"<div>{_linkify(line, card_links)}</div>" for line in reversed(snap["log"]))
    paused = " · <b style='color:#c0392b'>PAUSED</b>" if snap["paused"] else ""
    return f"""<!doctype html><meta charset=utf-8>
<meta http-equiv=refresh content=5>
<title>LoopWorker · {html.escape(snap['project'])}</title>
<style>
 body{{font:13px ui-monospace,Menlo,monospace;margin:2rem;color:#222}}
 table{{border-collapse:collapse;margin:1rem 0}}
 td,th{{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}}
 .log{{background:#f6f6f6;padding:.6rem;max-height:50vh;overflow:auto;white-space:pre-wrap}}
 .thinking{{max-width:34rem;color:#555;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
</style>
<h2>LoopWorker · {html.escape(snap['project'])}{paused}</h2>
<div>started {snap['started_at']} · poll every {snap['poll_interval']}s</div>
{_slots_table(snap["slots"], card_links)}
<h3>log</h3><div class=log>{log}</div>
"""


def serve(provider: SnapshotProvider, port: int = 8787) -> threading.Thread:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            snap = provider()
            if self.path.rstrip("/") == "/json":
                body = json.dumps(snap, indent=2).encode()
                ctype = "application/json"
            else:
                body = _render(snap).encode()
                ctype = "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):  # silence per-request logging
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    t = threading.Thread(target=httpd.serve_forever, name="dashboard", daemon=True)
    t.start()
    return t
