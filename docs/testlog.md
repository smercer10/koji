# Test log

Append-only record of every strength and speed measurement, **including the ones that failed.**

This is the one thing `git log` cannot reconstruct: a failed branch gets deleted and takes its
result with it, so without this file the same dead idea gets retried every few months. A negative
result recorded here is worth as much as a positive one.

Newest entries at the bottom. Never edit or delete an entry — if it was wrong, append a correction.

## Format

```
### YYYY-MM-DD — <short change description>
- branch:   feat/<short>
- type:     SPRT | bench | perft
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05        (gain)
            elo0=-5 elo1=0 alpha=0.05 beta=0.05       (simplification)
- TC:       8+0.08
- book:     <opening book filename>
- result:   PASS | FAIL | inconclusive
- LLR:      <value> (<lower>, <upper>)
- Elo:      <point estimate> +/- <error>
- games:    <n> (W-L-D)
- bench:    <nodes>
- notes:    what was actually learned, and whether it is worth revisiting
```

For a `bench` entry, replace the SPRT fields with: nodes/sec before and after, the number of
repetitions, the observed variance, and the `perf stat` figures that matter. A single-run
comparison is not evidence and should not be logged as one.

---

## Entries

### 2026-08-10 — Phase 0 scaffolding
- type:     none
- result:   n/a
- bench:    0 (stub — no search exists yet)
- notes:    Repository created. Toolchain pinned to Zig 0.16.0; build, test, test-slow and bench
            steps verified; OpenBench `Makefile` contract verified with `EXE=Engine-ABCDEFGH`.
            No engine code yet, so nothing to measure. The first real entry will be the Phase 1
            perft baseline.
