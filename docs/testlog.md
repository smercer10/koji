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

### 2026-08-12 — Sliding attacks: PEXT with fancy-magic fallback
- branch:   feat/magics
- type:     none (infrastructure; correctness gated by ray-scan-oracle tests, both schemes
            tested on every machine regardless of which one is active)
- result:   n/a
- bench:    0 (stub — no search exists yet)
- notes:    Scheme is comptime from the build target: PEXT iff BMI2 and not Excavator/Zen 1/Zen 2
            (microcoded PEXT). This Zen 3 box takes the PEXT path; `-Dcpu=x86_64` builds take
            magics.

            The planned find-magics-at-startup design was measured and rejected. Seeded
            random-sparse search (Romstad's method), all 128 squares, ReleaseFast on Zen 3:
            2676ms — the per-candidate `memset` of the collision table is 93% of it (1.42M
            trials, 124M subset probes; the high-byte popcount filter saves ~35% of trials but
            time stays memset-bound). Generation counters instead of clearing: 185ms. Still pure
            per-process waste, and paid precisely on the old-AMD targets that take the magic
            path — so the constants are hardcoded (our own, seed "koji") and the search is
            test-only, with a test that re-runs it and asserts equality with the hardcoded table.
            Romstad's published "under a second" is apparently post-folklore-optimisation; the
            naive-but-published form is 15x slower on hardware 20 years newer.

            Startup A/B (`koji version`, 200 runs, ~1.1ms process baseline): init = table fill
            only, ~0.40ms on both schemes. `zig build test` warm: 215ms including regenerating
            all 128 magics in ReleaseSafe.
