"""_pick_summary scrapes the worker's latest thinking/talking line from pane text,
skipping claude's box-drawing / prompt / footer chrome."""
from loopworker.tmux import _pick_summary

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
