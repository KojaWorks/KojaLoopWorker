# LoopWorker.app — the Mac menu-bar Manager

A SwiftUI menu-bar app that **supervises** the `loopworker` Manager and **shows its status** —
the Mac half of [Phase 1 in the distribution plan](../docs/distribution.md). It does not
reimplement any Manager logic; it is a client of the seams the Manager already exposes:

- **status** — polls `GET /health` and `GET /json` on the local dashboard (`127.0.0.1:8787`)
- **readiness** — runs `loopworker doctor --json` (the "why won't it start" host-prereq sweep)
- **control** — launches `loopworker` as a child process and maps the app's lifecycle onto the
  Manager's existing **signal contract**:
  - **Stop (drain)** → `SIGINT` — current workers finish, no new ones start, then it exits.
  - **Force stop** → `SIGTERM` — reap workers, release their claimed cards back to Backlog.
  - **Quit** drains, then holds app termination (`.terminateLater`) until the Manager actually
    exits — so it never leaves a headless Manager behind. A hard **Force-Quit** (`SIGKILL`)
    can't be intercepted; use *Force stop* to release cards. An app *crash* can orphan a
    (crash-safe) Manager — adopting it on next launch is a follow-up.
  It relaunches the Manager on an unexpected exit, bounded to 3 **consecutive** crashes (the
  counter clears after it stays up ~60s), so a startup crash-loop surfaces instead of hot-looping.

## Files

| File | Role |
| --- | --- |
| `project.yml` | xcodegen spec (source of truth; the `.xcodeproj` is generated + git-ignored) |
| `Sources/LoopWorkerApp.swift` | `@main` App — the `MenuBarExtra` scene + health-driven icon |
| `Sources/AppState.swift` | polls the contract, owns the controller, drives the UI |
| `Sources/ManagerController.swift` | the subprocess supervisor + signal mapping |
| `Sources/StatusClient.swift` | `/health`, `/json`, and `doctor` client |
| `Sources/ProcessRunner.swift` | async Process wrapper + `loopworker` binary locator |
| `Sources/MenuContentView.swift` | the popover: header, readiness, slots, controls |
| `Sources/Updater.swift` | Sparkle "Check for Updates…" (guarded by `#if canImport(Sparkle)`) |
| `Sources/Models.swift` | Codable structs for the status contract |
| `freeze-manager.sh` | freezes the Python Manager (PyInstaller) into `Resources/loopworker` at build time |
| `loopworker_entry.py` | PyInstaller entry shim (absolute import so the package is collected) |

## Build & run

```bash
cd macapp
xcodegen generate            # regenerate after adding/removing a Source file
open LoopWorker.xcodeproj     # ⌘R to run
# or, compile-check from the CLI:
xcodebuild -project LoopWorker.xcodeproj -scheme LoopWorker -configuration Debug \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**Self-contained.** A build phase (`freeze-manager.sh`) freezes the Python Manager with
PyInstaller and drops it into `Resources/loopworker`, so the app runs with **no `loopworker`
installed on the machine at all** — that's what "update the app == update the Manager" buys.
Because of that, the *build machine* needs **python 3.11+** on PATH (the freeze is skipped on
rebuilds when the binary is already fresh, so only the first build pays for it). The app
resolves the Manager in order: a `loopworkerPath` user-default override → the bundled
`Resources/loopworker` → `loopworker` on `PATH` (handy for `pip install -e .` dev loops).

## Status: scaffold — compiles, not yet verified as a running app

This builds clean (`xcodebuild … BUILD SUCCEEDED`) but has **not** been driven as a live GUI —
that needs a logged-in desktop session and a human. To verify manually:

1. Have a `loopworker` on PATH and `~/.loopworker/config.toml` set up.
2. Run the app; confirm the menu-bar icon appears and the popover shows readiness + (once you
   press Start) the Manager's slots, matching `http://127.0.0.1:8787`.
3. Exercise Start → Stop (drain) → Force stop and confirm the Manager reacts (watch the log).

## Not done here (own cards — see the distribution epic)

- **Sparkle**: add the SPM package (`https://github.com/sparkle-project/Sparkle`) to `project.yml`;
  the code activates via `#if canImport(Sparkle)`. Needs an appcast (`SUFeedURL`) + hosting.
- **Developer ID signing + notarization**: required before distributing outside your own machine.
  Note: the embedded frozen Manager (`Resources/loopworker`) is a Mach-O that must be signed too
  (sign it before the outer `.app`, then notarize the whole bundle).
- **Login-item toggle** and **settings UI** (dashboard port, loopworker path).
