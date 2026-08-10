---
name: sprt
description: Run an SPRT to decide whether a change is a real Elo gain, and record the result. Use for any change that could affect playing strength.
---

# SPRT — the strength test

SPRT is the only authority on strength. Nothing that touches search or eval merges without one.

## Build both sides identically

Any difference in optimisation, CPU flags, or Zig version between the two binaries invalidates the
result before a single game is played.

```
git switch main   && zig build -Doptimize=ReleaseFast && cp zig-out/bin/koji /tmp/koji-base
git switch <feat> && zig build -Doptimize=ReleaseFast && cp zig-out/bin/koji /tmp/koji-test
```

## Bounds

| Change | Bounds |
|---|---|
| A gain | `elo0=0 elo1=5` |
| A simplification (expected neutral, want to prove it doesn't lose) | `elo0=-5 elo1=0` |

`alpha=0.05 beta=0.05` in both cases.

## Run it

Time control `8+0.08`, with `-repeat -recover`. Set concurrency from the machine rather than a fixed
number — leave two threads spare so the engines are not fighting the harness for CPU:

```
CONCURRENCY=$(( $(nproc) - 2 ))
```

Use an UHO-style opening book, the OpenBench default. **Verify the exact book filename when fetching
it**; books are gitignored.

fastchess is built from source into `tools/fastchess/` (gitignored — it is a tool, not a dependency).

```
./tools/fastchess/fastchess \
  -engine cmd=/tmp/koji-test name=test \
  -engine cmd=/tmp/koji-base name=base \
  -each tc=8+0.08 -rounds 2 -repeat -recover -concurrency $CONCURRENCY \
  -openings file=books/<book>.epd format=epd order=random \
  -sprt elo0=0 elo1=5 alpha=0.05 beta=0.05
```

**Run this via background Bash, never in the foreground** — it takes hours and would block the
session for all of them.

**Before starting: check nothing else is measuring.** An SPRT owns the whole machine and a
concurrent run invalidates both results. (Policy and rationale: CLAUDE.md and `docs/decisions.md`.)

## Record it

Append to `docs/testlog.md` in the documented format: change, bounds, TC, book, LLR, Elo ±, games,
bench, and notes.

**Log failures too.** That is the entire point of the file — a failed branch gets deleted and takes
its result with it, so an unrecorded failure will be retried in six months by someone with no way of
knowing. A negative result is worth as much as a positive one.
