"""A tiny local HTTP status page. The Manager is already a long-lived process, so
serving its in-memory snapshot is nearly free and gives real-time visibility."""
from __future__ import annotations

import html
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

SnapshotProvider = Callable[[], dict]


def _render(snap: dict) -> str:
    rows = "".join(
        f"<tr><td>{s['index']}</td><td>{s['state']}</td><td>{s['port']}</td>"
        f"<td>{'~' + str(s['card']) if s['card'] else '—'}</td>"
        f"<td>{html.escape(s['session'] or '—')}</td>"
        f"<td>{s['started_at'] or '—'}</td></tr>"
        for s in snap["slots"]
    )
    log = "".join(f"<div>{html.escape(line)}</div>" for line in reversed(snap["log"]))
    paused = " · <b style='color:#c0392b'>PAUSED</b>" if snap["paused"] else ""
    return f"""<!doctype html><meta charset=utf-8>
<meta http-equiv=refresh content=5>
<title>LoopWorker · {html.escape(snap['project'])}</title>
<style>
 body{{font:13px ui-monospace,Menlo,monospace;margin:2rem;color:#222}}
 table{{border-collapse:collapse;margin:1rem 0}}
 td,th{{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}}
 .log{{background:#f6f6f6;padding:.6rem;max-height:50vh;overflow:auto;white-space:pre-wrap}}
</style>
<h2>LoopWorker · {html.escape(snap['project'])}{paused}</h2>
<div>started {snap['started_at']} · poll every {snap['poll_interval']}s</div>
<table><tr><th>slot</th><th>state</th><th>port</th><th>card</th><th>session</th><th>started</th></tr>
{rows}</table>
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
