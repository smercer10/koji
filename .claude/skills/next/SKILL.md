---
name: next
description: Session opener — orient in the repo, state the next task, and branch for it.
disable-model-invocation: true
---

# Start a session

This has side effects (it creates a branch) and is a manual opener, not something to trigger
mid-task. It is a default, not a gate: to work on something off-roadmap, just say so instead.

1. Read, in this order:
   - `git status` and `git log --oneline -5` — what is in flight and what just landed.
   - The first unchecked item in `ROADMAP.md` — what is next.
   - The last few entries of `docs/testlog.md` — so a just-failed idea is not immediately retried.
2. State in one or two sentences: the current phase, the next task, and anything the testlog says
   was already tried and failed here.
3. If `main` is dirty or a feature branch is unmerged, say so and stop — finish that first.
4. Otherwise `git pull --ff-only` on `main`, then create `feat/<short>` off it.
5. Enter plan mode for anything non-trivial. Skip planning only when the change is small and
   obvious (a constant, a typo, a test).
