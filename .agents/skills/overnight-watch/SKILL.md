---
name: overnight-watch
description: Procedure for a stretch of unsupervised work while the captain sleeps - when the captain says "I'm going to sleep", "move forward on the queue, make decisions, don't wait for me", or "update me in the morning". Owns the pre-flight done while the captain is still awake, the authority envelope for the night, dispatch pacing on this machine, queue continuity through the whole night, the wake-handling habits that keep a fleet moving without a human, the incident playbook for the failures that recur at night, and the mandatory shape of the morning report.
metadata:
  internal: true
---

# overnight-watch

Load this the moment the captain announces a sleep stretch and hands over the queue.
It is written from the night of 2026-09-03 to 2026-09-04, when ten deliverables were driven to PRs unsupervised and every mistake below was made at least once.
`AGENTS.md` sections 7, 8 and 9 stay the authority for delivery, supervision and captain etiquette; this skill only adds what a night without the captain changes.

## 1. Pre-flight - do this while the captain is still awake

The captain can fix a blocked permission or a locked credential in ten seconds now and not at all at 03:00.
Before saying goodnight, prove every command the night will need actually runs in this session:

1. Run one real `bin/fm-pr-merge.sh` on a PR the captain has already approved, or a `--help` of it, and one real spawn through the project's required launch form (the click-bateva credential-sandbox wrapper carries `--dangerously-skip-permissions`, which an auto-mode classifier may refuse).
   A refusal now is a one-line question to the captain; a refusal at 01:00 strands the whole queue.
2. Check that every remote the fleet will push to is SSH, not HTTPS: `git -C <clone> remote get-url --push origin` for each project and for this repo's fork.
   The macOS keychain credential helper blocks HTTPS pushes with no timeout at night, and the pipeline's push step then hangs forever without noticing.
3. Read machine headroom: `sysctl vm.swapusage` and `top -l 1 -n 0 | grep PhysMem`.
   On this 4-CPU, 8 GB machine about eight concurrent Claude workers is the ceiling; below ~500 MB unused or above ~2 GB swap, stop dispatching.
4. Read the live queue with `tasks-axi list` and keep that listing: the morning report must show the queue before and after.
5. Ask the captain the two authority questions in section 2 in one sentence each if the answers are not already explicit.

## 2. Authority envelope for the night

"Make decisions, don't wait for me" is a current explicit captain instruction and covers every ask-user finding, every routing choice and every delivery-mode call, decided under `ask-user-authority` and recorded in the task's status log.
It does not cover the boundaries `AGENTS.md` keeps behind the captain's own words: a merge on a project without standing `yolo`, a red merge anywhere, anything destructive or irreversible (branch deletion, environment retirement, data changes), credentials, and logins.
Ask about merges explicitly before the captain leaves: a captain who "does not read PRs" wants everything landed and will say so; a captain who does not say so gets a list of PRs in the morning.
A login-gated step (wp-admin, a cloud console) is parked with a `paused:` line naming exactly what the captain must open, and the worker is stood down until morning.

## 3. Dispatch pacing

Dispatch in the order that frees the captain fastest in the morning: ship tasks that were already committed and merely blocked, then in-flight research, then fresh research, then new ship work.
Launch one spawn at a time and watch the timeout: a spawn that dies after `treehouse get` and before the agent launches leaves a tmux window and a pooled worktree with no task record; kill that window and respawn.
When headroom is gone, park the newest work with `bin/fm-control.sh <id> exit` (a fresh scout costs nothing to relaunch with `relaunch --note`) rather than letting spawns race the pipelines.
Every relaunch of a scout requires `--note`; write what the replacement inherits and what changed since.
Stand down every worker whose deliverable is done and waiting on the captain (`bin/fm-control.sh <id> exit`); its worktree and record stay for teardown after landing, and the freed memory goes to the next task.

## 4. Queue continuity - the night is not over while ready work exists

The night of 2026-09-03 lost five hours because the last worker finished at 05:39 and firstmate then reported hourly that nothing needed doing while ten ready, unblocked items sat in the queue; section 3 orders only the first dispatch, and this section makes the re-check mandatory for the whole night.
The queue re-check is a fixed step after every worker completion, every stand-down, every cleanup, and on every heartbeat wake: run `tasks-axi ready`, read headroom per section 1 step 3, and dispatch the next ready items up to the machine ceiling, in section 3's order.
The night's work is finished only when the ready queue is empty, or headroom is gone, or every remaining ready item is blocked by the section 2 envelope; in the last two cases the hold message names each remaining item and its blocker.
A hold message that says nothing needs doing while ready items exist is forbidden; every hourly hold line states the ready count and the headroom reading.
A usage-limit stop is a paused wait with a known reset time; the first turn after the reset runs the queue re-check before anything else.
When away mode is on, overnight-watch composes with the `afk` skill, and the away-mode daemon's self-handled heartbeat wakes still trigger this section's queue re-check.

## 5. Wake handling habits that keep the night moving

- Drain, read, act, acknowledge, every wake; the stale wakes for stood-down workers are noise and are acknowledged in one command.
- A no-CI repository (click-bateva, bateva-shelanu, this fork) parks every pipeline at the ci step forever.
  Put the standing ci-wait instruction in the first steer to every worker on such a repo: once every step through pr is completed, end the wait through the supported path and report `done: PR <url> (no CI configured; gate = <evidence> on head <sha>)`; the project's local gate is the gate.
- A worker whose pane shows a shell still running for more than ten minutes at a push, ci, or approve step is usually blocked inside a synchronous `no-mistakes axi` call; `bin/fm-control.sh <id> interrupt` frees it, then steer with the recovery sequence.
- A `paused:` line with a usage-limit reset time is a real external wait; steer the worker back the moment the clock passes it.
- Every steer that answers a keyed `needs-decision:` or `blocked:` passes `--resolve-key`; a `paused:` line has no key, so resend without one when `fm-send` refuses.
- After each completion, record the PR in the morning report file immediately rather than reconstructing it at dawn.

## 6. Incident playbook - the failures that recur at night

- **Pipeline push hangs, zero bytes, no git process or a git process older than a few minutes**: the HTTPS credential helper.
  Kill the hung `git push` and `git-remote-https`, switch the remote to SSH, have the worker run `no-mistakes init` to re-record the remote.
  The daemon does not notice a dead push step; when `axi abort` keeps returning `terminal_confirmed=false`, confirm this is the only active run (`sqlite3 ~/.no-mistakes/state.sqlite "select id,status,branch from runs where status='running'"`), then `no-mistakes daemon restart --force` followed by `no-mistakes daemon start` when the restart stops without starting.
  The run then reads `failed` with `branch_sync` `pipeline_owned`; the worker follows `next_action`, recovers custody, and starts one fresh run.
- **Two PreToolUse hook shells of one worker at ~17% CPU for minutes**: that worker's tool call is wedged; kill both hook processes and the worker continues.
- **Load average in the hundreds with swap near full**: memory, not CPU; park work per section 3 and do not restart anything.
- **A PR merged this morning conflicts with siblings merged before it**: relaunch its worker with a note that the rebase-step conflict is its own branch against the new base, so `--action fix` at rebase is correct there.

## 7. The morning report

The captain reads the report instead of the PRs, so it must be complete and it must be organized around what the captain asked, not around what firstmate did.
Write it to `data/status-report-<date>.md` as the night goes and finish it before the captain wakes.
Its sections, in this order, are mandatory:

1. **What you asked, and where each one stands** - one line per captain request from the evening, including the ones asked in passing, each mapped to its task id and current state; a request that produced no task says so.
2. **Queue before and after** - the `tasks-axi list` snapshot from pre-flight against the morning one, so the captain sees what moved.
   This section must also list every idle interval longer than 30 minutes during the night with its cause, so an unexplained gap is visible rather than buried.
3. **Landed and ready** - every PR with its full URL, one line on what it does, and whether it is merged, ready under standing authority, or waiting on the captain.
4. **Decisions made for you** - each ask-user or routing call, the option chosen and why in one line.
5. **Findings** - each finished investigation as findings, with the captain calls filed for it.
6. **Needs you** - logins, permissions, merges outside standing authority, destructive calls, in the order that unblocks the most.
7. **Incidents** - what broke, what was done about it, and what was recorded in `data/learnings.md`.

The chat message in the morning is a short pointer at that file plus the "Needs you" list; it is not a substitute for the file.
