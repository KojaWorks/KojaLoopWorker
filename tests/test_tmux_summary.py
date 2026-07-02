"""_pick_summary scrapes the worker's latest thinking/talking line from pane text,
skipping claude's box-drawing / prompt / footer chrome."""
from loopworker.tmux import _pick_summary, looks_like_trust_prompt

PANE = """\
❯ You are dijkstra, an autonomous LoopWorker.
  ...brief...
⏺ I'll start by reading my loop instructions and the card details.
✢ Percolating… (24s · ↑ 237 tokens)
─────────────────────────────────────────────────
❯
─────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents
"""


def test_picks_latest_thinking_line():
    assert _pick_summary(PANE) == "✢ Percolating… (24s · ↑ 237 tokens)"


def test_falls_back_to_last_step_when_no_spinner():
    pane = "⏺ Editing app/src/views/NewView.tsx\n───\n❯\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
    assert _pick_summary(pane) == "⏺ Editing app/src/views/NewView.tsx"


def test_empty_when_only_chrome():
    assert _pick_summary("───\n❯\n  ⏵⏵ auto mode on (shift+tab to cycle)\n\n") == ""


def test_skips_tip_line_below_the_real_thinking():
    pane = (
        "⏺ Editing app/src/views/NewView.tsx\n"
        "  ⎿  Tip: Use /btw to ask a quick side question without interrupting Claude's current work\n"
        "───\n❯\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
    )
    assert _pick_summary(pane) == "⏺ Editing app/src/views/NewView.tsx"


def test_detects_folder_trust_prompt():
    # The ACTUAL Claude Code dialog wording (observed on a fresh clone), not the first guess.
    dialog = (
        "Accessing workspace:\n"
        "/Users/nevyn/Dev/loopworker-clones/kojaserv.loopworker-slots/slot-0\n"
        "Quick safety check: Is this a project you created or one you trust?\n"
        "❯ 1. Yes, I trust this folder\n"
        "  2. No, exit\n"
        "Enter to confirm · Esc to cancel\n"
    )
    assert looks_like_trust_prompt(dialog)
    # normal worker panes must NOT match — we must never send a stray key into a live session
    assert not looks_like_trust_prompt(PANE)
    assert not looks_like_trust_prompt("⏺ Reading files…\n✢ Percolating (12s)")
    assert not looks_like_trust_prompt("")


def test_spawn_injects_declared_env_before_command(monkeypatch):
    """Regression: worker env vars go into the session via `-e`, before the command — so a
    worker sees a secret the tmux server's frozen env doesn't have."""
    import types
    from loopworker import tmux

    seen = {}
    def fake(*a):
        seen["args"] = a
        return types.SimpleNamespace(returncode=0, stderr="")
    monkeypatch.setattr(tmux, "_tmux", fake)

    tmux.spawn("sess", "/tmp/wt", ["bash", "run.sh"], env={"PATCH_DEV_SECRET_KEY": "shh"})
    a = seen["args"]
    assert a[0] == "new-session"
    i = a.index("-e")
    assert a[i + 1] == "PATCH_DEV_SECRET_KEY=shh"      # -e KEY=VALUE
    assert i < a.index("bash")                          # flags precede the command
