---
name: retro
description: Agent-only procedure for the retro a ship task owes before it validates and lands. Use before starting validation or opening a PR on an eligible ship, and when teardown refuses for a missing or invalid retro receipt. Owns tier selection, the questions each tier asks, deduplication against knowledge that already exists, the routing of each lesson to its owner, and the receipt the destructive-boundary backstop reads.
metadata:
  internal: true
---

# Retro

A ship that taught something and shipped anyway wasted the lesson.
This skill runs at the one moment the lesson is still cheap to keep: after the implementation is right and before validation begins, while the worker still holds the context and its own branch is still open.

Do not run this after landing.
By then the branch is merged, validation is over, and a project rule discovered now cannot travel in the change that discovered it.
`bin/fm-teardown.sh` refuses cleanup for a ship with no receipt, but that refusal is the backstop for direct-PR and local-only paths and for workers that shipped before the receipt existed - not the trigger.

## When it applies

Ship tasks only.
A scout's deliverable is already knowledge, and a persistent secondmate is not one task, so neither is retro-gated.

Choose the tier honestly; the point is a real lesson, not a filled-in form.

- **quick** - any non-trivial ship, any `fix:` commit, any unexpected correction during the work, or any task whose implementation diverged from the plan it was given.
- **full** - a multi-commit feature or refactor, a new subsystem, a long-running workstream, or an explicit workstream closeout.
- **skip** - available only to a task that shipped under a planning exemption and stayed inside it.
  A planned ship was already classified non-trivial and cannot skip, and neither can a task that outgrew its exemption; `bin/fm-retro-lib.sh` owns that test and refuses at teardown.

## Quick

Answer three questions, in the branch, before validation:

1. What did this task teach that a future session would otherwise rediscover?
2. Would a reviewer have caught the bug this task fixed, given what the project's reviewers currently read?
3. Did anything in the standing process get skipped, worked around, or misread here?

If all three answers are "nothing", record `Retro: quick` with that as the reason and move on.
A retro that honestly finds nothing is a real outcome.

## Full

Everything quick asks, plus:

4. What shape did this subsystem turn out to have, and where is that written down?
5. Which decisions were reversed during the work, and what would have surfaced them earlier?
6. What is now true that the project's `AGENTS.md`, its skills, or its reviewers still contradict?

## Deduplicate before writing anything

Search for the lesson before adding it.
Read the project's `AGENTS.md`, its existing `.claude/review-rubrics/`, its skills, and its docs.
A rule that is already written, or that a stricter existing rule already implies, is not a finding; sharpening the existing wording is better than adding a second copy of it.
Never create empty or boilerplate rubric files to populate a directory: a rubric exists to make a reviewer catch a concrete, recurring, reviewer-actionable thing, and one that names nothing specific makes reviews noisier, not better.

## Route each lesson to its owner

Only project-owned outcomes are yours to write, and they land in THIS branch, before validation, so they ship with the change that produced them:

- A rule other contributors need: the project's committed `AGENTS.md`, through `bin/fm-ensure-agents-md.sh`.
- A check a reviewer should have made: `.claude/review-rubrics/<lens>.md` in the project, as a concrete check with the failure it catches.
- A behavior that broke: a regression test.
- A map or doc the project already owns: that file.

Everything else is a candidate, not an edit.
You cannot write outside your worktree - the receipt at the path your brief names is the single exception - so name it on the receipt and let firstmate apply it after inspect-then-update:

- **home-learning** - a fleet-local operational fact or gotcha, for `data/learnings.md`.
- **captain-preference** - something the captain wants that is not yet written down, for `data/captain.md`.
- **shared-firstmate** - a change to firstmate's own shared tracked material, which becomes a separately authorized firstmate-repo task and never an opportunistic edit from here.

Task chronology - what you tried, what failed, how long it took - stays in the receipt and the task record. Do not promote it.

## The receipt

Write `data/<task-id>/retro.md` before validation or PR creation:

```text
Retro: quick|full|skip
Reason: <why this tier applies>
Routes:
- project-change: <path committed in this branch, or none: reason>
- home-learning: <candidate text for firstmate, or none: reason>
- captain-preference: <candidate text for firstmate, or none: reason>
- shared-firstmate: <follow-up needed, or none: reason>
```

`bin/fm-retro-lib.sh` owns exactly what that file must contain and when a skip is available.

## What this is not

It is not a second review.
The selected delivery path owns review, fixes, tests, docs, push, PR, and CI (`AGENTS.md` section 7), and a retro must never hold a green PR for a subjective verdict or run a parallel reviewer.
Its output is implementation - a test, a doc line, a rubric entry - produced before validation starts, or it is a candidate handed to firstmate.
