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

## The book

`UHO_Lichess_4852_v1.epd`, the OpenBench default. Books are gitignored — 175MB extracted — so this
is a fetch, not a checkout:

```
git clone --filter=blob:none --sparse --depth 1 \
  https://github.com/AndyGrant/openbench-books.git tools/openbench-books
git -C tools/openbench-books sparse-checkout set --no-cone '/UHO_Lichess_4852_v1.epd.zip'
mkdir -p books && unzip -q -o tools/openbench-books/UHO_Lichess_4852_v1.epd.zip -d books
sha256sum books/UHO_Lichess_4852_v1.epd
# 7a7f6470615a69c6cf23d565417701d38732876f480af90d67b42abade35644a
```

The sha is OpenBench's own (`Books/*.json` in `AndyGrant/OpenBench`) and checksums the **extracted**
`.epd`, not the zip — a truncated book is a silently worse SPRT, not an error.

Clone rather than fetch the URL in that manifest: `guard.sh` blocks raw-file and `contents/` reads
and leaves repository roots alone so shared tools stay reachable. The books repo is data only — no
engine source, and no declared licence, so nothing from it is vendored or credited.

fastchess is built from source into `tools/fastchess/` (gitignored — it is a tool, not a dependency).

```
./tools/fastchess/fastchess \
  -engine cmd=/tmp/koji-test name=test \
  -engine cmd=/tmp/koji-base name=base \
  -each tc=8+0.08 -rounds 25000 -repeat -recover -concurrency $CONCURRENCY \
  -openings file=books/UHO_Lichess_4852_v1.epd format=epd order=random \
  -sprt elo0=0 elo1=5 alpha=0.05 beta=0.05
```

`-rounds` is only a ceiling — the SPRT stops itself as soon as either LLR bound is hit.

**Run this via background Bash, never in the foreground** — it takes hours and would block the
session for all of them.

**Before starting: check nothing else is measuring.** An SPRT owns the whole machine and a
concurrent run invalidates both results. (Policy: CLAUDE.md, Workflow.)

## Record it

Append to `docs/testlog.md` using the format block at the top of that file. **Log failures too** —
a deleted branch takes its result with it, and an unrecorded failure gets retried.
