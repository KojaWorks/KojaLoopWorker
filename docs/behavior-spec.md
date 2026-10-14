# Behavior spec

This file lists the behaviors that the Swift Manager must have, one testable row each, with the Python origin that a porter can read. Where a row and [../DESIGN.md](../DESIGN.md) disagree, DESIGN.md wins.

The Origin column cites the Python implementation, which was deleted after commit `8742f58331`; read a cited file with `git show 8742f58331:<path>`.

Status: `keep` ports the Python behavior as is; `fix` states the corrected behavior for a Python gap or bug; `changed` states the behavior that the new design puts in place of the Python one; `patch` only matters for the Patch backlog (round 2). Python paths are under `loopworker/`, tests under `pytests/`. "untested" means no pytest covered it, so the Swift test is the first one.

## ProcessRunner

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B01 | Every child runs in its own process group. When the timeout expires, the whole group gets SIGKILL and the result has `timedOut = true`; a timeout counts as failure even when the caller ignores the exit status. | keep | `slots.py:414-495`; `test_run_script_timeout_kills_whole_process_group` |
| B02 | `ProcessSpec.timeout` is required for every call, including git and tmux. No code path starts a subprocess without one. | fix | `slots.py:497-504`, `host.py:358-372`, `tmux.py:18-21` (no timeout); untested |
| B03 | Every child gets stdin from `/dev/null`, so a Manager started by launchd or a GUI with no valid fd 0 can run scripts that open stdin (for example `python3 -m venv`). | keep | `slots.py:439-446`; `test_run_script_gives_the_script_a_real_stdin` |
| B04 | Every child gets `GIT_TERMINAL_PROMPT=0`, so git fails instead of waiting for a credential prompt. | fix | none set anywhere; untested |
| B05 | `run` returns when the child exits, even when a grandchild still holds the output pipe open: it drains for at most 5 s, then stops reading. Lines that arrive after that are dropped, never logged against a later card. | keep | `slots.py:447-488` (untested for scripts), `authgate.py:86-127`; `test_check_does_not_hang_when_grandchild_holds_pipe_real` |
| B06 | Output is read while the child runs, so a child that writes more than the pipe buffer never deadlocks. | fix | `macapp/Sources/ProcessRunner.swift:16-23`; untested |
| B07 | Cancelling the task that awaits `run` kills the child's process group. | changed | none (DESIGN.md "Concurrency") |
| B08 | `run` throws only when the process can't start (for example a missing binary). A non-zero exit, a signal or a timeout is a `ProcessResult`. Callers treat a start failure as a failed check, never as a crash. | keep | `authgate.py:86-127`, `readiness.py:73-90`; `test_check_missing_binary_is_failure_real`, `test_claude_missing_binary_is_fail_not_crash`, `test_unexpected_error_counts_as_failure_not_a_crash` |
| B09 | `onLine` receives each line of merged stdout and stderr as it arrives, already redacted (B112). | keep | `slots.py:447-488`; `test_run_script_streams_and_captures_port` |

## Tmux

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B10 | Worker sessions are named `lw_<project key>_<slot index>` (`SlotSpec.session`), so a session name never depends on a card ref, and the prefix `lw_<key>_` can't match another project whose key extends this one. | changed | `manager.py:379-380` (`lw-<proj>-<num>`); untested |
| B11 | Every tmux call runs through ProcessRunner with a 10 s timeout. A timed-out tmux call is an error for that slot this tick, never "session dead". | fix | `tmux.py:18-21`; untested |
| B12 | The Manager runs tmux with `-S $LOOPWORKER_HOME/state/tmux`, its own server socket, so two Manager homes on one host never see or reap each other's sessions, and a human's own tmux server is untouched. | fix | D3, `manager.py:399-405`; untested |
| B13 | `sessions(prefix:)` returns `[]` when no tmux server is running and throws on any other failure. A failed listing is never read as "no sessions". | fix | `tmux.py:129-135` (returns `[]` on any failure); untested |
| B14 | `isAlive` is true when the session exists and its pane's process hasn't exited (`pane_dead` is 0; panes are kept on exit). The foreground command is not used: it is a shell whenever claude runs a command. An idle `claude` that has finished counts as alive; the outcome file says when it is done. | fix | `tmux.py:14-38`; untested |
| B15 | `spawn` passes no secret in tmux arguments. Every tmux command runs with the backlog and forge token variables and `CLAUDE_CODE_OAUTH_TOKEN` removed from its environment, so the tmux server never holds them; the launch script's `env -i` is the second layer. | fix | `tmux.py:41-49` (token in `-e` argv, visible in `ps`); untested |
| B16 | Auth-failure detection matches only claude's own chrome: `Please run /login · API Error` or `Not logged in · Please run /login`, anchored on the `·` separator. A pane that merely contains the words (a worker editing this code, test output) does not match. | keep | `tmux.py:78-93`; `test_detects_login_prompt`, `test_healthy_pane_is_not_an_auth_failure`, `test_no_false_positive_on_self_referential_work` |
| B17 | Folder-trust detection matches any of `trust this folder`, `Accessing workspace`, `one you trust`, `do you trust`, `trust the files`, case-insensitive. | keep | `tmux.py:63-75`; `test_detects_folder_trust_prompt` |
| B18 | The activity line for the status file is the most recent non-empty pane line in the last 40 lines that is not chrome (lines starting with `─ ❯ ⏵ │ ╭ ╰ ⎿`, or containing `mode on (shift+tab` or `esc to interrupt`), cut to 140 characters. It is empty on any failure. | keep | `tmux.py:108-127`; `test_picks_latest_thinking_line`, `test_falls_back_to_last_step_when_no_spinner`, `test_empty_when_only_chrome`, `test_skips_tip_line_below_the_real_thinking` |
| B19 | Killing a session that doesn't exist is not an error. | keep | `tmux.py:52`; untested |

## Git

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B20 | Git timeouts: clone 30 min, fetch and push 10 min, local commands (worktree, reset, clean, checkout, rev-list) 2 min. A timeout is a failure of that step with the command named. | fix | `slots.py:497-504`, `host.py:218`, `host.py:358-372`; untested |
| B21 | Every git call that talks to the forge gets `Forge.gitEnvironment()`. Credentials never appear in argv or in a remote URL. | changed | `host.py:358-372` (ambient user credentials); untested |
| B22 | The Manager clones each project to `<clones_dir>/<key>` at startup and refreshes it (fetch, then `syncCheckout` to `origin/<base>`) every 5 minutes as a project task, then re-reads the repo's contract from that working tree. A failed refresh keeps the cached clone, logs the git error and retries at the next refresh. | changed | `host.py:349-373`; `test_ensure_clone_refreshes_existing_clone` (failure path untested) |
| B23 | Slot worktrees live at `<clones_dir>/<key>.slots/<n>/`, never inside the clone. Each sits on the flat local branch `loopworker-slot-<n>`, because `loopworker/...` collides with a branch named `loopworker`. | keep | `slots.py:89-91`, `slots.py:381-387`; untested |
| B24 | `resetWorktree` runs fetch, `reset --hard origin/<base>`, `clean -fd`, then removes ignored agent files (`clean -fdx -- .claude CLAUDE.local.md`), `checkout -B <card branch>`, and logs the resolved base commit. The Manager resets on every acquire and never trusts the state that the previous card left. | fix | `slots.py:216-242`; `test_cold_pool_provisions_on_acquire_then_tears_down` (git mocked) |
| B25 | The card branch comes from the contract's `[worker] branch` template, default `loopworker-{number}-{slug}` (slug lowercase ASCII, at most 40 characters). The default is flat, so a repo branch named `loopworker` can't collide with it; a template without `{number}` or `{slug}` is rejected at load. | changed | `slots.py:216-242` (`claude/<slug>`), scar 20; untested |
| B26 | `commitsAhead` counts commits on HEAD that `origin/<base>` doesn't have. | changed | none |
| B27 | `push` force-updates the card branch on the forge, so a finish retried after a restart succeeds. | changed | none (workers pushed with `gh`) |
| B156 | Every git command the Manager runs sets `GIT_LFS_SKIP_SMUDGE=1`, so clone, reset and checkout leave LFS pointer files and never download, even when the host's or repo's config installs a smudging LFS filter. | changed | none |
| B157 | `usesLFS` is true when a `.gitattributes` at any depth in HEAD contains `filter=lfs`. `lfsPull` runs `git lfs install --local --skip-smudge --skip-repo` (the worker's checkouts don't download either, and no hooks are installed), then `git lfs pull` with the contract's include and exclude patterns, under the contract's pull timeout. Both run with the credentialed flags and the forge's environment, with `lfs.url` and `lfs.pushurl` set to `<clone URL>/info/lfs`, so no endpoint comes from repo config. | changed | none |
| B158 | `lfsPush` runs `git lfs push origin HEAD` with the same flags, endpoint and environment, under a 60 min timeout. It uploads the objects that HEAD references and no `origin/*` tracking ref does; `-c remote.origin.url=<clone URL>` keeps `origin` valid when the worker removed the remote. | changed | none |
| B28 | `removeWorktree` runs `git worktree remove --force` then `git worktree prune`. It logs failures and never throws. | keep | `slots.py:153-178`, `slots.py:275-281`; `test_teardown_timeout_stays_best_effort` |

## SlotLifecycle

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B29 | Lifecycle scripts run from the contract directory with `LOOPWORKER_SLOT_DIR` (the worktree) and `LOOPWORKER_PORT` (the slot's first port) set. | keep | `slots.py:432-433`; `test_run_script_streams_and_captures_port` |
| B30 | A script may print a line `LOOPWORKER_PORT=<n>`; the slot then reports `<n>` as its port in the status file. Without that line the status file shows no port for the slot. | keep | `slots.py:29`, `slots.py:405-407`; `test_run_script_streams_and_captures_port`, `test_capture_port_absent_leaves_port_unreported` |
| B31 | Lifecycle script timeouts default to provision 45 min, reset 15 min and teardown 10 min, overridable per contract. | keep | `config.py:43-53`; `test_defaults` |
| B32 | While a script runs, the log gets a "still running" line every min(300 s, timeout/2). | keep | `slots.py:466-472`; `test_run_script_timeout_kills_whole_process_group` |
| B33 | Script output streams into the log line by line, redacted. A failed script raises a SlotFailure that carries the script name, the exit status or timeout, and the tail of its redacted output. | keep | `slots.py:414-495`; `test_run_script_raises_with_tail_on_failure` |
| B34 | `prepare` on a hot slot ensures the worktree and runs `provision.sh` once. On a cold slot it does nothing. | keep | `slots.py:113-125`; `test_cold_pool_build_provisions_nothing` |
| B35 | `acquire` on a cold slot runs `provision.sh`; `recycle` on a cold slot runs `teardown.sh`. On a hot slot, acquire runs `reset.sh` and recycle detaches HEAD, so an idle slot never holds a card branch that another slot needs. | fix | `slots.py:216-264`; `test_cold_pool_provisions_on_acquire_then_tears_down` |
| B36 | A failed acquire on a cold slot runs `teardown.sh` for whatever stack it started before the slot is marked broken. | keep | `manager.py:326-339`; untested |
| B37 | Teardown is best effort: a timeout or a missing script is logged, and the worktree removal still runs. `recycle` and `retire` never throw. | keep | `slots.py:275-281`; `test_teardown_timeout_stays_best_effort` |
| B38 | A failed provision or reset marks the slot broken. Fill skips broken slots while healthy slots keep working. A project with zero healthy slots logs a WARNING. | keep | `slots.py:113-125`; `test_build_time_broken_hot_slot_alerts_through_wired_notifier` |
| B39 | A slot's last failure lives in its own `lastError` field, so retry activity can't overwrite why it broke. Only a successful provision clears it; returning a cold broken slot to the pool keeps it. | keep | `models.py:116-133`, `slots.py:322-326`, `slots.py:398-401`; `test_last_error_survives_the_retry_loop`, `test_reprovision_success_clears_the_failure_record`, `test_revive_broken_resets_cold` |
| B40 | A broken cold slot returns to the pool on the next tick. A broken hot slot is re-provisioned in place as a slot task, at most once per 180 s measured from when the previous attempt finished, with the clock read per slot. | keep | `slots.py:291-351`; `test_revive_broken_reprovisions_hot_in_place`, `test_revive_broken_hot_failure_backs_off_before_retrying` |
| B41 | A failed script whose output matches the engine-down pattern sets `SlotFailure.engineDown`. | keep | `engine.py:26-39`, `slots.py:239-241`; `test_looks_like_engine_down_matches_daemon_errors`, `test_provision_failure_flags_engine_down` |
| B42 | Before re-provisioning engine-down slots, the Manager runs one engine recovery shared by all of them. If recovery fails, every engine-down slot backs off; slots that broke for another reason skip recovery. | keep | `slots.py:306-314`, `slots.py:393-395`; `test_revive_broken_recovers_engine_then_reprovisions`, `test_revive_broken_skips_engine_recovery_for_non_engine_break`, `test_revive_broken_backs_off_when_engine_stays_down` |
| B43 | Engine recovery is a host task: it runs `engine.start_command` (default `orb start`, 60 s timeout), then runs `engine.probe_command` (default `docker ps`, 15 s timeout) until it succeeds or 90 s pass. It does nothing when the probe already succeeds. | keep | `engine.py:69-107`; `test_recover_noop_when_engine_already_up`, `test_recover_starts_engine_and_waits_until_reachable` |
| B44 | The 300 s recovery backoff starts before the start command runs, so a hung start still delays the next attempt. A start command that fails to launch counts as a failed recovery, not a crash. | keep | `engine.py:69-107`; `test_recover_backs_off_before_re_running_start`, `test_recover_survives_a_start_command_that_raises` |
| B45 | Engine recovery notifies when it starts an attempt and when it gives up. `engine.recover = false` disables it. | keep | `engine.py:69-107`; `test_recover_gives_up_after_probe_timeout_and_notifies` |
| B46 | One engine recovery and one auth gate exist per Manager, shared by all projects. | keep | `host.py:79-92`; partly `test_host.py` |
| B47 | The weighted budget is `max_slots`. A project can afford `floor(remaining / weight + 1e-9)` more slots, so a weight like 0.1 doesn't undercount. | keep | `host.py:38-52`; `test_affordable_tolerates_fractional_weight_float_error`, `test_apply_slot_targets_spends_budget_in_weighted_units` |
| B48 | Hot pools are capped to the weighted budget in one place, used at startup and on every config change. | fix | D8, `host.py:405-420` vs `host.py:315-347`; `test_build_caps_hot_pools_to_weighted_budget`, `test_apply_slot_targets_caps_hot_to_budget` |
| B49 | A cold project's slot count is capped at `max_slots`, so its slots never leave its port band. | keep | `host.py:305-339`; `test_apply_slot_targets_caps_cold_to_max_slots` |
| B50 | Each project gets a port band of `port_step * max(ceil(max_slots), 1)` ports starting at `base_port + band index * band size`. Band indexes are allocated lowest free first and reused after a project leaves. Slot `n` uses `band start + n * port_step`. | keep | `host.py:375-389`; untested |
| B51 | Broken hot slots don't count against the budget, so cold projects can use it. | keep | `slots.py:353-358`, `host.py:537-541`; `test_fill_all_broken_hot_slot_frees_budget_for_cold` |
| B52 | Shrinking a pool retires the highest idle slots first. A busy slot is flagged retiring and retired after its card finishes. Growing cancels retirement before adding slots, and only new slots are provisioned. Targets count non-retiring slots only. | keep | `slots.py:131-151`, `slots.py:206-213`, `slots.py:254-264`; `test_resize_grow_provisions_only_new_slots`, `test_resize_shrink_tears_down_highest_idle_first`, `test_resize_shrink_defers_a_busy_slot_until_recycled`, `test_resize_up_revives_a_retiring_slot` |
| B159 | When the contract's `[lfs] pull` is true and `usesLFS`, `acquire` (after the reset) and hot `prepare` (after ensuring the worktree) run `lfsPull` with the project's forge URL and environment before any script. The log gets the pull's start and duration. A failed pull is a SlotFailure that names the step and carries the redacted git output, like a failed provision. | changed | none |
| B53 | At startup, slot worktree directories on disk that the pool doesn't track get `teardown.sh`, `worktree remove` and `worktree prune`, best effort. The check is keyed on pool membership, never on a count, and never touches a busy slot's worktree. | keep | `slots.py:153-178`; `test_reap_orphans_tears_down_dirs_beyond_the_pool`, `test_reap_orphans_keeps_a_busy_slots_worktree` |

## Reconciler

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B54 | A busy slot whose card is gone (`card(_:)` returned nil) is abandoned: reap, recycle, no backlog write. | changed | `reconciler.py:35-36`; `test_card_gone_is_reap`; Swift `goneCardIsAbandoned` |
| B55 | A busy slot whose card is in any state other than `working` is abandoned at once, even when an outcome file exists. | changed | `reconciler.py:37-38` (reap after 120 s grace); `test_card_left_in_progress_is_reap`; Swift `cardMovedByAHumanIsAbandonedEvenWithAnOutcome` |
| B56 | An outcome file means `finish`: at once when the session is dead, otherwise after the outcome is 20 s old. An outcome beats the wallclock cap. | changed | `manager.py:222-233`; `test_spawn_keep_reap_cycle`; Swift `outcomeWaitsForGraceWhileSessionIsAlive`, `outcomeFinishesAtOnceWhenSessionIsDead`, `outcomeBeatsTheWallclockCap` |
| B57 | A dead session with no outcome while the card is `working` is `release(crashed)`. | keep | `reconciler.py:40-41`; `test_dead_while_in_progress_is_crash`, `test_crash_reclaim`; Swift `deadSessionWithoutOutcomeIsACrash` |
| B58 | A live pane showing the auth-failure chrome (B16) is `release(auth)`, before the wallclock check. A card that left `working` is abandoned even when the pane shows an auth failure. | keep | `reconciler.py:45-46`; `test_auth_failure_is_reclaim`, `test_auth_failure_after_card_done_still_reaps`, `test_auth_wedged_worker_is_reclaimed` |
| B59 | A worker running longer than the contract's `wallclock_cap_minutes` (default 90) is `release(hung)`. | keep | `reconciler.py:47-48`, `config.py:34`; `test_over_wallclock_is_hung`; Swift `overTheCapIsHung` |
| B60 | A crash or hang release that would bring the card's failed attempts to `max_attempts` (default 3) calls `markStuck` instead, with a blocker that gives the attempt count and this release's reason (earlier reasons are on the card as release notes). Auth releases and Manager-restart releases don't count as attempts. | fix | scar 25, `DESIGN.md:280-283` (old); `test_crash_reclaim` needed PAUSED to stop the loop |
| B61 | Reconcile skips a slot that has a running task (acquire, finish, recycle, re-provision) until the task records its result on the slot. | changed | D4; none |
| B62 | A backlog read that throws for one busy slot skips that slot this tick and logs it. Other slots and projects still reconcile. A thrown read is never treated as "card gone". | fix | scar 51, `manager.py:208-211`, `host.py:466-484`; untested |
| B63 | One Manager per backlog identity and project is a documented constraint (DESIGN.md "Reconcile"); the Manager doesn't detect a second Manager claiming under the same identity. The slot's `card.json` is the local record of which card a slot holds. | changed | D10/scar 27, `reconciler.py:24-49`, `manager.py:368` (`worker_id` never read); untested |

## Manager

### Loop and fill

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B64 | A tick runs every 15 s and only observes and starts tasks: tmux reads, outcome file reads, one `card(_:)` per busy slot, at most one `workable(in:)` call, and task starts. Acquire, finish, recycle, provision, clone refresh, engine recovery, the auth preflight and notify run as tasks with timeouts. | changed | D4, `host.py:466-488`; none |
| B65 | An error that escapes a tick is logged as `ERROR in tick` with the error, and the next tick runs on schedule. | keep | `manager.py:154-164`, `host.py:466-484`; untested |
| B66 | An error in one project's fill or reconcile is logged for that project and doesn't skip the other projects in the same tick. | fix | scar 51, `host.py:518-553`; untested |
| B67 | A Manager with zero configured projects idles and keeps ticking; it does not exit. | keep | `host.py:451-458`; `test_run_idles_with_no_projects_then_picks_one_up` |
| B68 | A project without a project contract (no `manifest.toml` in the repo or overlay) is not served. The log and the status file name the missing path, and the Manager checks again after each clone refresh. | keep | `host.py:195-303`; `test_discover_skips_project_without_contract` |
| B69 | Fill calls `workable(in:)` once per tick, only when a free slot exists and the auth gate and the concurrency cap allow a start, passing only projects with a free slot. A failed read claims nothing this tick and is never treated as "no cards". | fix | D5, `host.py:518-553`, `patch.py:251-284`; untested |
| B70 | Fill starts at most one worker per tick host-wide, hot projects first, and never exceeds `max_concurrent_workers` (default `ceil(max_slots)`) running workers. | keep | `host.py:518-553`, `config.py:69-74`; `test_fill_all_starts_one_worker_per_pass_hot_first`, `test_fill_all_respects_concurrency_cap`, `test_fill_all_falls_through_to_cold_when_hot_idle`, `test_fill_all_cold_starts_one_when_weighted_budget_affords_it`, `test_fill_all_cold_blocked_by_weighted_budget` |
| B71 | A slot only receives a card whose `project` matches the slot's project path case-insensitively. A mismatch is logged as an error and the card is not claimed. | fix | D2, `manager.py:297-298`; `test_no_project_filter_when_worker_manager_unset` locked in the bug |
| B72 | The host killswitch `state/PAUSED` and the project killswitch `state/projects/<key>/PAUSED` are checked every tick. A paused project claims nothing; its busy slots still reconcile and finish. | changed | `manager.py:157-160`, `host.py:471-482` (`state/host/...`); partly `test_crash_reclaim` |
| B73 | The startup log says whether `CLAUDE_CODE_OAUTH_TOKEN` is set. | keep | `host.py:109-112`; untested |

### Claim, acquire and spawn

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B74 | The Manager deletes any previous outcome, then writes `card.json` (card ref, project, slot, branch, base, time) into the slot state directory, then calls `claim`, then starts the acquire task. A lost claim (`false`) deletes `card.json` and skips the card. Recycle also deletes the outcome, so an old outcome never meets a new `card.json`. | changed | `manager.py:314-324`; `test_claim_returns_false_when_no_row` (adapter only); Manager level untested |
| B75 | Any failure between a successful claim and a live session (acquire, file writes, spawn) releases the card with a reason that names the failed step and its error, and recycles the slot. A failed acquire also marks the slot broken. | fix | scars 33, 34, `manager.py:326-361`; untested |
| B76 | A `release` that throws is logged as ERROR with the card ref and the error; the card is then left to stranded-card recovery. No release failure is swallowed. | fix | scar 24, `manager.py:335-338`, `manager.py:357-360` (`except Exception: pass`); untested |
| B77 | Before spawn, the Manager deletes any previous outcome, snapshot, brief and launch script in the slot state directory, so an old outcome can never finish a new card. | changed | none |
| B78 | The snapshot, the brief, the launch script and the MCP config are written to `$LOOPWORKER_HOME/slots/<key>/<n>/`, never into the worktree, so a worker's `git add -A` can't commit them. | fix | D11, `manager.py:468-492`; untested |
| B79 | The snapshot file holds `CardSnapshot.markdown` followed by its `excluded` lines; each excluded line is also logged. | changed | none |
| B80 | The brief is the built-in worker brief followed by the contract's `BRIEF.md`, if present. | changed | `manager.py:419-458`, `patch.py:63-73`; `test_host_mode_build_prompt_uses_injected_brief` |
| B177 | The brief's verify step has the worker re-run a failing check in a temporary worktree at `origin/<base>` and remove it afterwards. A failure that also happens there is pre-existing: the worker leaves it alone unless the card asks, and lists it with evidence under "Pre-existing failures" in the outcome body. Only failures the change causes block the card. | fix | none |
| B81 | The launch script is executable, runs `unset USER` (claude-code 2.1.201 returns 401 with USER set and MCP tools loaded), exports `LOOPWORKER=1` and `LOOPWORKER_OUTCOME`, and execs `claude --permission-mode auto` with the brief read from a file, never typed in with send-keys. | keep | `manager.py:465-493`; `test_spawn_keep_reap_cycle`, `test_launch_*`; `LOOPWORKER=1` untested |
| B82 | The model is the card's `model`, else the project's `model`; with neither, `--model` is omitted. The value is shell-quoted. | keep | `manager.py:460-463`; `test_launch_omits_model_flag_when_unset`, `test_launch_uses_card_model_over_project_default`, `test_launch_falls_back_to_project_default_model`, `test_launch_shell_quotes_a_hostile_model_value`, `test_snapshot_carries_resolved_model` |
| B83 | The worker gets `--strict-mcp-config` with the contract's `mcp_config` file, or no MCP servers when the contract declares none. | changed | `config.py:28` (`[worker] mcp` never read; user-scope MCPs); untested |
| B84 | The worker's environment is built by the launch script from `env -i`, plus a 0600 env file in the slot state directory: `CLAUDE_CODE_OAUTH_TOKEN` plus each name in the project's host-config `worker_env` (never the repo contract). A listed name that the Manager doesn't have is logged as a warning. Backend tokens are never in the Manager's environment, so they can't be listed. | fix | `manager.py:42-45`, `manager.py:343-351`, `tmux.py:41-49`; `test_default_auth_env_forwarded_to_worker`, `test_spawn_injects_declared_env_before_command` |
| B85 | After spawn, a task captures the pane for up to 15 s and presses Enter only after the folder-trust text (B17) appears. | keep | `manager.py:35-70`; watcher untested |
| B86 | Each spawn is logged with project, slot, card ref, branch, base commit and model. | keep | `manager.py:372`; untested |

### Finish

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B87 | Finish runs as a slot task. A `done` outcome with zero commits ahead of the base becomes `stuck` with the blocker "reported done, but the branch has no commits ahead of <base>". | changed | none |
| B88 | For `done`, finish pushes the branch, attaches the guide if one is named and the forge supports attachments, opens a review request (draft per the project's `draft` setting) whose body ends with the guide link and the card ref, then calls `markReview`. | changed | none (workers did this with `gh`) |
| B89 | The outcome's `guide` resolves against the slot state directory. A path that resolves (after symlinks) outside it, or doesn't exist, is not attached; the log says why and the review request opens without the guide. | changed | none |
| B90 | For `stuck`, finish pushes the branch when it has commits ahead of the base, then calls `markStuck` with the blocker and the branch name. An unparseable outcome file is `stuck` with the parse error as the blocker. A `BackendRejection` during a `done` finish also ends as `stuck`, with the rejection as the blocker. | changed | none; Swift `garbageBecomesStuckNotAnError`, `doneWithoutTitleBecomesStuck`, `parsesStuck` |
| B178 | A claimed card whose push-ledger entry names the same branch resumes it: the Manager fetches the clone, and when `origin/<branch>` exists, acquires from that branch and the brief gets a "Resuming" section. When the branch is gone, the card starts from the base and its ledger entry is dropped; a failed check releases the card (not counted) and leaves the ledger alone. Finish still counts commits ahead of the project base. | fix | none |
| B91 | The slot is recycled only after finish succeeds. A failed finish logs the failed step, keeps the outcome file and retries on later ticks, backing off from 30 s doubling to 10 min; after 3 consecutive failures it notifies once and the status file shows the slot as "finish failing". | fix | none (retry is new; the bound is a choice) |
| B160 | Before pushing a card branch (`done`, or `stuck` with commits), finish runs `lfsPush` with the forge URL and environment when `usesLFS`, so the forge never gets pointers to content it lacks. A failed LFS push is a failed finish step, retried with backoff (B91). | changed | none |
| B92 | A finish that succeeds clears the auth circuit breaker's streak (B98). | keep | `authgate.py:129-154`, `manager.py:203-250`; `test_clean_reap_clears_auth_backoff`, `test_clean_completion_resets_the_backoff_streak` |

### Stranded-card recovery, startup and shutdown

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B93 | At startup, the Manager adopts each live session whose slot `card.json` names a card that the backlog still reports `working`, and reaps every other `lw_<key>_*` session on its tmux server before building the slot pool, so no unadopted worker holds a worktree that the pool resets. | changed | `manager.py:399-405`, `host.py:421-423`; `test_reap_orphans_at_startup` (release path untested) |
| B94 | At startup and every 5 minutes, the Manager calls `working(in:)` and compares it with its slots. A `working` card named by a slot's `card.json` with an outcome file is finished; one without an outcome is released with reason "Manager restarted". A `working` card that no slot of this home names is released with reason "the Manager lost track of this card's worker", not counted as an attempt. A failed `working(in:)` read changes nothing. | fix | D1/scar 23, `base.py:33-36`, `patch.py:298-300` (dead code); untested |

### Waiting for CI

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B164 | A project without `[review] wait_for_ci` moves a finished card to `review` right after opening the review request, and its CI is never read. | changed | none |
| B165 | With `wait_for_ci`, finish opens the review request, writes the watch record `state/ci/<card id>.json` (card, project, branch, base, pushed commit, review request, round, push time) atomically, then moves the card to `verifying` and frees the slot. The record is written first, so a `verifying` card always has one. | changed | none |
| B166 | The Manager polls every watched card every 120 s: it re-reads the card (a card that left `verifying` outside the loop stops the watch and deletes its record), then reads the newest pipeline for the pushed commit, so a re-run or a pipeline started by a branch push counts. | changed | none |
| B167 | A passed pipeline (success, skipped, or only manual jobs left) moves the card to `review` with a note that links it. Still running `ci_timeout_minutes` after the push, no pipeline 15 min after the push, a canceled pipeline, or a forge that can't be read until the timeout marks the card stuck, naming the commit and linking the pipeline and the review request. Every exit deletes the watch record. A failed move backs off 30 s doubling to 10 min, re-reading card and pipeline before each retry, and notifies at the third failure in a row. | changed | none |
| B168 | A failed pipeline with fix rounds left queues a fix round. Fill starts queued fix rounds before new claims, within the same budget and `max_concurrent_workers`. The round first re-reads the pipeline: passed moves the card to review and running waits for it, so a human's re-run wins. It then calls `resumeFix` (false: a human moved the card, so the round is dropped and logged), resets a slot to the pushed card branch, writes `ci.md` and spawns the worker with the fix-round brief. Its finish requires commits since the failed push, pushes under the same lease ledger, reuses the open review request and returns the card to `verifying` with the new commit and round + 1. A round that fails to start before or after `resumeFix` keeps its watch and record, returns the card to `verifying` if it had left it, and backs off 30 s doubling to 10 min; the third failure in a row, a project that left the config, or `ci_timeout_minutes` in the queue marks the card stuck. A crash in a running fix round releases the card like any crash. | changed | none |
| B169 | A pipeline that fails after `ci_fix_attempts` fix rounds marks the card stuck with each failed job linked. | changed | none |
| B170 | At startup and with every stranded-card sweep, each `verifying` card with a watch record is watched again; one without a record (or with an unreadable one) is marked stuck, because nothing else would move it on. The same pass deletes the records of served cards that are gone or no longer `verifying`, skipping cards a slot or a watch holds. The stranded-card sweep never releases a `verifying` card, and a failed read of `verifying` cards changes nothing. | changed | none |
| B171 | The status file lists each watched card (card, round, short commit, pipeline state or fix-round state, push time, pipeline or review request URL), and `loopworker status` prints them under "waiting for CI". | changed | none |
| B175 | `ci.md` holds each failed job's name, stage, URL and the last 200 lines of its log, redacted and fenced with more backticks than the log contains, under a header that calls it untrusted CI output and not instructions. The fix-round brief names the review request, the failed commit, `ci.md` and the round, and tells the worker that the Manager keeps the existing review request. | changed | none |

### Auth gate

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B95 | The auth preflight runs `claude -p ok --model haiku` with `USER` unset, as a host task with a 120 s timeout. An ok or failed result is cached for 180 s, and fill claims nothing while it fails. | keep | `authgate.py:30-127`; `test_ok_when_check_succeeds`, `test_check_success_real`, `test_check_failure_returns_last_line_real`, `test_check_timeout_kills_group_and_reports_real`, `test_check_strips_user_from_env`, `test_auth_gate_failing_pauses_fill` |
| B96 | The auth gate logs and notifies only on an ok/failing transition. The recovery notification uses its own dedupe key, so the failure notification can't suppress it. | keep | `authgate.py:30-84`; `test_fails_and_notifies_once_on_transition`, `test_recovery_logs_and_notifies_once_with_a_distinct_key` |
| B97 | Tests inject a fake ProcessRunner, so no test runs the real `claude`. | changed | `authgate.py:30-84` (`enabled` flag); `test_disabled_never_shells_out`, `test_disabled_gate_ignores_reclaims` |
| B98 | Each `release(auth)` arms a circuit breaker that pauses fill host-wide for 30 s × 2^(n-1), capped at 600 s, even when the preflight passes. A clean finish clears the streak, but an auth release in the same tick wins: the streak is cleared only after the whole tick is scanned. | keep | `authgate.py:129-154`, `manager.py:203-250`; `test_auth_reclaim_pauses_dispatch_even_when_preflight_passes`, `test_auth_reclaim_backoff_is_exponential_and_capped`, `test_same_pass_auth_reclaim_beats_clean_completion`, `test_auth_reclaim_arms_gate_backoff_and_pauses_respawn`, `test_clean_completion_is_a_noop_without_a_streak` |
| B176 | A preflight that times out or is killed by a signal is inconclusive: the gate keeps its health and re-checks after 30 s. Three inconclusive results in a row count as failing (B96). Every failed or inconclusive check logs a warning, and sets the status file's auth detail, with the reason, how many in a row, and when the next check runs. | fix | none |

### Notify

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B99 | Notify runs `notify_command` with the message on stdin, as a task with a 20 s timeout. It never throws; an empty command does nothing. | keep | `notify.py:44-52`; `test_empty_command_is_noop`, `test_sends_message_on_stdin`, `test_notify_command_failure_is_logged_not_raised` |
| B100 | Notifications are deduplicated per key for 300 s; different keys both send. | keep | `notify.py:36-71`; `test_dedupes_same_key_within_window`, `test_different_keys_both_fire` |
| B101 | A non-zero exit is logged. Output that is Pushover JSON with `status != 1` is logged as a rejection; JSON with `status == 1` is silent; other output is ignored. | keep | `notify.py:36-71`; `test_nonzero_exit_is_logged`, `test_pushover_rejection_is_logged`, `test_pushover_success_is_silent`, `test_non_json_output_is_left_alone`, `test_shipped_example_command_delivers_a_plain_message` |
| B102 | At startup the Manager sends a self-test notification; with no `notify_command` the log says that alerts are DISABLED. | keep | `host.py:494-503`; `test_notify_self_test_pings_on_boot`, `test_notify_self_test_warns_when_disabled` |
| B103 | A slot becoming broken notifies once per transition, keyed by slot identity rather than index, because a resize reuses indexes. | keep | `manager.py:259-280`; `test_broken_slot_notifies_once`, `test_broken_slot_notifies_again_after_index_reuse` |
| B104 | A card marked stuck at `max_attempts` notifies with the card ref, the attempt count and the last release reason. | fix | scar 25; none |

### Signals and drain

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B105 | The first SIGINT drains: no new claims; running workers and their finish tasks complete; the Manager exits when no slot is busy and no task runs. | keep | `manager.py:553-571`; `test_draining_starts_no_new_workers`, `test_sigint_escalates_drain_then_force` |
| B106 | The second SIGINT, or any SIGTERM, force-stops: cancel running tasks (which kills their process groups), reap every worker, release each card that is still `working` with reason "Manager stopped", recycle cold slots, then exit. Hot stacks stay up. | keep | `manager.py:168-173`, `manager.py:382-414`, `host.py:489-492`, `host.py:590-605`; `test_sigterm_force_stops_immediately`, `test_reap_workers_on_shutdown` (host handler untested) |
| B107 | The third SIGINT exits immediately with status 130. | keep | `manager.py:553-571`; `test_third_sigint_hard_exits` |

### Lock, state paths and status file

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B108 | Every state path derives from `LOOPWORKER_HOME` (default `~/.loopworker`), never from the working directory. | fix | D3, `host.py:69`, `__main__.py:193`; Swift `homeComesFromTheEnvironment` |
| B109 | One Manager per home: `state/manager.lock` is held with `flock` for the process lifetime and holds the pid. A second Manager exits with a message naming the holder's pid. A stale or corrupt lock file never blocks or crashes startup. | fix | scar 70, `manager.py:573-584`, `host.py:607-618` (TOCTOU, `int(pid)` crash, reused pid); untested |
| B110 | `state/status.json` is written atomically (temp file, then rename) every tick. It holds the pid, version, start and update times, host and project pause state, the auth gate state, and per slot: state, card ref and URL, running time, activity line (B18), port, last error and running task. | changed | `dashboard.py`, `manager.py:503-525`; `test_json_carries_version_stamps`, `test_health_host_shape` |
| B111 | The version is single-sourced from the build and appears in `--version`, the status file and the startup log. | fix | D13, `__init__.py:16`, `pyproject.toml:3`; `test_version_flag` |

### Logging and redaction

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B112 | The LogSink redacts every line before it reaches any output: the log file, stdout and the status file. `onLine` callbacks and script output pass through the same redaction. | fix | scar 62/D12, `manager.py:532-536`, `host.py:579-583`; `test_redacts_secrets_before_disk` (file only) |
| B113 | Redaction replaces JWTs, `sb_secret_` and `sb_publishable_` keys, hex strings of 32 or more characters, postgres URL passwords, GitLab tokens (`glpat-`, `gloas-`, `glrt-` prefixes), and the literal values of the configured backlog and forge token variables. | keep | `slots.py:45-61`; `test_redact_scrubs_stack_secrets` |
| B114 | `state/manager.log` rotates at 10 MB and keeps 5 files. Each line starts with a UTC timestamp. | keep | `filelog.py:27-55`; `test_writes_full_timestamped_line`, `test_rotates_when_full` |

## Config

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B115 | `$LOOPWORKER_HOME/config.toml` is the only source of projects and scheduling (slots, hot, weight, model, base branch). Nothing is read from a backlog's tables, and the project contract holds no scheduling. | changed | D7, `host.py:102-108`, `config.py:191-206`; `test_discover_builds_managers_and_applies_row` |
| B116 | `[backlog] kind` is required. `max_slots` must be > 0 (default 4), `max_attempts` must be > 0 (default 3), `max_concurrent_workers` defaults to `ceil(max_slots)`, a project's `slots` must be >= 0. Each violation is a ConfigError naming the key. | keep | `config.py:56-147`; `test_host_config_missing_required_key`, `test_max_concurrent_workers_explicit_override`; Swift `minimalConfigGetsDefaults`, `backlogKindIsRequired` |
| B117 | A project weight <= 0 counts as 1. | keep | `host.py:36-43`; `test_apply_slot_targets_ignores_zero_or_negative_weight`; Swift `nonPositiveWeightCountsAsOne` |
| B118 | Two projects whose paths map to the same key are rejected at load, naming both paths. | fix | D3 (`_slug` collisions); Swift `projectsWithTheSameKeyAreRejected` |
| B119 | Engine config defaults to `recover = true`, `start_command = "orb start"`, `probe_command = "docker ps"`, defined in one place that doctor also reads. | fix | S9, `config.py:95-96`, `engine.py:45-46`, `readiness.py:91`; `test_host_config_engine_defaults`, `test_host_config_engine_override` |
| B120 | Secrets come from the environment variables that the config names (`token_env`), never from config.toml. A named variable that is unset fails startup with a message naming it. | changed | `config.py:61`, `patch.py:116-122`; untested |
| B121 | A missing project manifest is an error that names the path. A lifecycle timeout <= 0 is rejected at load. | keep | `config.py:43-53`; `test_missing_manifest_raises`, `test_nonpositive_script_timeout_rejected_at_load` |
| B122 | A project's `contract` overlay replaces the repo's `.loopworker/` entirely. | changed | none |
| B161 | The contract's `[lfs]` table is optional: `pull` (default true), `include` and `exclude` (git-lfs path patterns, default empty), `pull_timeout_minutes` (default 60). A timeout <= 0, or a pattern containing a comma (git-lfs's list separator), is rejected at load. | changed | none |
| B163 | The contract's `[review]` table may set `wait_for_ci` (default false), `ci_timeout_minutes` (default 120, must be > 0) and `ci_fix_attempts` (default 2, must be >= 0); an invalid value names the key and the file. | changed | none |
| B123 | A malformed config file is reported as malformed (with the decoder's message and the file path), never as missing, and never as a raw stack trace. | fix | `__main__.py:43-47`, `config.py:198` (KeyError); `test_doctor_surfaces_malformed_config_not_missing`, `test_host_config_missing_file` |

## GitLabBacklog and GitLabForge

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B124 | A card is `ready` only when it is trusted: assigned to the token's user, the system note that assigned that user was written by that user, the latest `loopworker:next` label event was added by that user, and its project path starts with an `allowed` prefix. Anything else is never returned by `workable`, and each skipped card is logged once. | changed | scar 46, `patch.py:208-269`; `test_gate_*` |
| B125 | The trust cutoff is the human's `loopworker:next` label event; a Manager release keeps the earlier cutoff, recorded in its release note. The snapshot holds the title and description only if the token's user edited them last or they were last edited before the cutoff, and comments written by that user or last edited before the cutoff. Notes the Manager posted are always left out. Every left-out piece is named in `excluded`. | changed | none |
| B126 | Every list read follows pagination to the last page. A page that fails throws; a partial list is never returned. | fix | scar 50, `patch.py:235`, `patch.py:252`; untested |
| B127 | `CardRef.id` is `<project id>/<iid>`. A moved issue becomes a new issue with a new id, so `card(_:)` returns nil for the old ref and its worker is abandoned. `card(_:)` also returns nil when the issue is deleted or outside the allowed projects. | fix | 2b, `manager.py:379-380`, `models.py:39`, `reconciler.py:35-36`; untested |
| B128 | `CardRef.display` and every note the Manager writes use GitLab notation: `group/project#iid` for issues, `!iid` for merge requests. `~` is never used for a card, because GitLab reads it as a label. | changed | 2b, `manager.py:316-427`, `dashboard.py:21-33` |
| B129 | Card states map from `loopworker:*` labels, plus the work-item status field when `status_mode = "work_item_status"`. An unknown combination is `other`, never an error. | changed | scar 21, `models.py:23-32`; `test_card_status_parse_tolerates_unknown`, `test_unknown_status_card_is_skipped_not_crashing` |
| B130 | `workable` sorts by priority descending, then oldest first, so equal priorities don't flap between ticks. | keep | `patch.py:385-390`; `test_list_workable_filters_and_sorts` |
| B131 | `claim` re-reads the issue and returns false unless it is still `ready`, then swaps `loopworker:next` for `loopworker:working` in one request. Failed attempts are recorded by `release(countsAsAttempt: true)` as a marked note, not by `claim`. | changed | scar 47, `patch.py:353-361`; `test_claim_returns_true_when_row_updated`, `test_claim_returns_false_when_no_row` |
| B132 | `release` posts the reason as a Manager note (recording the trust cutoff, and the failed-attempt marker when it counts) and then sets `loopworker:next`. `markStuck` sets `loopworker:stuck`, keeps the assignee and posts the blocker. `markReview` sets `loopworker:review` and links the merge request. All worker-written text has quick actions neutralized (a leading `/` is escaped). | fix | D9, `patch.py:363-371` (note ignored); untested |
| B133 | A 401 or 403 fails at once with an error that names the token variable. A 5xx or connection error throws and is retried on the next tick. A 429 waits for `Retry-After` before the next request to that host. Every request times out after 30 s. | changed | scar 44 (Patch shape); untested |
| B134 | `gitEnvironment` supplies the token through `GIT_ASKPASS`; `cloneURL` contains no credentials. | changed | none |
| B135 | `openReviewRequest` returns the open merge request for the source branch if one exists, and otherwise opens one. | changed | none |
| B136 | `attach` uploads the file to the project and returns its markdown URL. | changed | none |
| B172 | `verifying` is the `<prefix>ci` label; in `labels` and `work_item_status` mode its status defaults to the `working` status name (`[backlog.gitlab.status] verifying`). `markVerifying` needs a `working` card, `resumeFix` returns false unless the card is `verifying`, and `markReview` and `markStuck` accept both. `pipeline` reads the commit's 20 newest pipelines, keeps the newest per (ref, source) and drops child pipelines (`parent_pipeline`); any failed is failed, else any running is running, else any canceled is canceled, else passed (`success`, `skipped` and `manual` pass; anything else runs). For each failed one it reads the failed jobs that aren't `allow_failure` with the last 200 lines of each trace, color codes stripped; a trace that can't be read becomes that job's log tail. A Manager note whose body equals my newest note, with no label event since, is not posted again. | changed | none |

## GitHubForge

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B173 | `pipeline` folds the commit's latest check runs into one pipeline: none is nil; any run not completed is running; any `failure` or `timed_out` is failed, with each failing run as a job and its output text (else summary) as the log tail; any `cancelled` is canceled; all `success`, `neutral` or `skipped` pass; anything else counts as running. Pages are followed to `total_count`. The older commit status API is not read. | changed | none |

## PatchBacklog (round 2)

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B137 | PAT exchange at startup retries a 5xx or connect error with backoff from 10 s doubling to 120 s, within 600 s, then notifies and gives up. A 401 or 403 fails at once. At runtime it fails at once and the next tick retries. | patch | scar 44, `patch.py:38-43`, `patch.py:438-510`; `test_exchange_retries_transient_5xx_then_succeeds`, `test_exchange_retries_connect_error`, `test_exchange_fails_fast_on_auth`, `test_exchange_gives_up_and_notifies_after_budget`, `test_runtime_refresh_fails_fast_not_retried` |
| B138 | The token is re-exchanged 60 s before expiry, and a 401 triggers one re-exchange and one retry. | patch | `patch.py:438-510`; `test_request_retries_once_on_401`, `test_exchange_sets_bearer_and_caches` |
| B139 | The owner uid is decoded from the JWT `sub` before the token is cached; a decode failure leaves no usable token. | patch | scar 45, `patch.py:494-497`; `test_jwt_sub_decodes_and_rejects_bad_tokens` |
| B140 | Trust fails closed: a card counts only if `created_by` is the PAT owner or in a local `trusted_authors` list, never a list read from the database. Each untrusted card is logged once. | patch | scar 46, `patch.py:208-269`; `test_gate_drops_untrusted_author_card`, `test_gate_trusts_local_override_author`, `test_gate_drops_card_with_missing_author`, `test_gate_logs_each_gated_row_once` |
| B141 | `claim` is one PATCH filtered on `assignee=is.null`; it returns true only when a row changed. | patch | scar 47, `patch.py:353-361`; `test_claim_returns_true_when_row_updated`, `test_claim_returns_false_when_no_row` |
| B142 | `ready` means status Backlog, unassigned, not an epic, every `blocked_by` target Shipped (a missing target counts as blocking), and a `project` relation that names a configured project. A card without a project is never ready. Sort: priority descending, then lowest number. | patch | scar 48, `patch.py:251-292`, `patch.py:385-390`; `test_list_workable_filters_and_sorts`, `test_untagged_card_skipped_when_serving_multiple` |
| B143 | Relation cells are read as a scalar or an array. | patch | scar 49, `patch.py:180-206`; `test_relation_normalization`, `test_list_projects_tolerates_relation_cardinality` |
| B144 | An empty status is Backlog; an unknown status is `other`. In progress is `working`, Needs refinement is `stuck`. | patch | scar 21, `models.py:23-32`; `test_card_status_parse_tolerates_unknown` |
| B145 | Reads page through PostgREST ranges until a short page, so a `max-rows` cap can't truncate the result. | patch | scar 50, `patch.py:235`, `patch.py:252`; untested |
| B146 | `release` and `markStuck` write their reason into the card's page body. | patch | D9, `patch.py:363-371`; untested |
| B147 | Constructing the backend does no network I/O and reads no global environment; the token exchange happens on first use. | patch | 3b, `patch.py` `__init__`; `test_manager_integration.py:59-63` |
| B174 | `verifying` is its own status, `[backlog.patch.status] verifying` (default `Verifying`); every state's status must differ, and a duplicate names both keys. `resumeFix` is one PATCH filtered on the verifying status. `markVerifying` writes the review link field like `markReview`. | patch | none |

## CLI and doctor

| ID | Behavior | Status | Origin |
| --- | --- | --- | --- |
| B148 | `loopworker` with no subcommand runs the Manager for `$LOOPWORKER_HOME`. `--version` prints the build version. | changed | `__main__.py`; `test_version_flag` |
| B149 | `loopworker status` reads `state/status.json` and pretty-prints it. If the lock isn't held, it says no Manager is running; if the file is older than 60 s while the lock is held, it says the Manager is wedged and shows the last update time. | changed | `__main__.py:143-152`; `test_status_pretty_prints_a_host_snapshot`, `test_status_reports_no_manager_when_unreachable`, `test_status_empty_host_shows_no_phantom_project` |
| B150 | `loopworker doctor` checks claude (the preflight, B95; an inconclusive one fails with a re-run remedy), the container engine, `tmux`, `git` and `bash` on PATH, the config, and the backlog (reachable and the token accepted). Each check has a remedy line. | changed | `readiness.py`; `test_check_all_covers_every_dimension`, `test_tool_present_and_absent`, `test_backlog_connection_error_is_fail` |
| B151 | Doctor exits 0 when every required check passes; the engine check is recommended only, and a failing recommended check doesn't change the exit code. `--json` prints machine-readable results. | keep | `readiness.py:150-160`; `test_doctor_exit_zero_when_all_ok`, `test_doctor_exit_one_when_a_check_fails`, `test_doctor_json_is_machine_readable`, `test_doctor_recommended_failure_stays_ready`, `test_engine_is_recommended_not_required` |
| B152 | The claude remedy for a failed login is `claude setup-token` plus `CLAUDE_CODE_OAUTH_TOKEN`, because an interactive login doesn't reach headless workers. A failed check shows the last error line. | keep | `readiness.py:27-34`; `test_claude_remedy_points_at_setup_token_not_interactive_login`, `test_claude_bad_login_surfaces_last_error_line`, `test_claude_timeout_is_fail` |
| B153 | The engine remedy names the configured `start_command`, not a hardcoded one. A malformed probe result is a failed check, not a crash. | fix | 2d, `macapp/Sources/SetupView.swift:251`; `test_engine_down_gives_start_remedy`, `test_engine_malformed_probe_is_fail_not_crash` |
| B162 | A missing `git-lfs` is a doctor FAIL naming the projects whose existing clone uses Git LFS, and a warning when no clone does (or none exists yet). | changed | none |
| B154 | Doctor detail lines are redacted. | keep | `readiness.py:65-70`; `test_probe_detail_is_redacted` |
| B155 | `loopworker service install` writes a launchd plist (a LaunchDaemon with `UserName` when no user is logged in, otherwise a LaunchAgent) that sets `LOOPWORKER_HOME`, restarts on crash, and gives a stop 180 s (`ExitTimeOut`) so force-stop can release cards. | changed | scar 65, `packaging/loopworker.service:11-20`; `test_service_unit_is_wellformed` |

## Dropped

- **HTTP dashboard** (`dashboard.py`, `/json`, `/health`, the in-memory log ring buffer, `card_links`, the `~(\d+)` linkifier, the port 8787): replaced by `status.json` (B110) and `loopworker status`.
- **Mac menu-bar app** (adoption, crash relaunch, quit escalation, Keychain PAT and `.env` migration, login-shell PATH capture, Sparkle; scars 63, 66, 67, 68, D14): not part of the Swift Manager; a later app is a client of `status.json`.
- **PyInstaller freeze, entitlements, notarization, release workflow** (section 0, D15): the port ships one native binary through Homebrew.
- **Parent-death watchdog** (`LOOPWORKER_PARENT_PID`, scar 18): only the Mac app set it; launchd supervises the service.
- **systemd unit** (scar 65 Linux half): DESIGN.md ships launchd only.
- **Single-project mode** (`--project`, D2): the host config is the only project source.
- **Contract-authoring sessions** (`lw-scaffold-*`, scars 26, 71): a project without a contract is reported (B68) instead of having one written for it.
- **Worker writes to the backlog and forge** (section 2a: status changes, `solved_in_pr`, env-feedback table, `gh pr create`/merge): the worker only writes its outcome; the Manager finishes.
- **Patch-hosted brief** (`brief_pointer`, the "Managed Agent Loop" page, brief sources `patch-page`/`url`): the brief is built in plus `BRIEF.md` (B80).
- **`loop_workers` and `loop_managers` tables, `register_worker`, `register_manager` heartbeat, the projects table, `worker_manager`** (2b, S2, D6, D8): projects come from the host config; worker identity is the slot.
- **`.env` loader** (`test_load_dotenv`): secrets come from the environment variables that the config names (B120).
- **Reap grace of 120 s after the card leaves In progress** (scar 10): the outcome file is the done signal (B56) and a human state change abandons at once (B55).
- **Separate fill cadence of 300 s**: fill runs every tick (B69, B70).
- **`AuthGate.enabled` flag**: tests inject a fake runner (B97).
- **Python-only nits** (3b: dead code, the dashboard thread race, `_redact` living in `slots.py`, `_my_manager_id` misreporting): no Swift counterpart.
- **Docs findings S1-S11**: documentation work, not Manager behavior.
