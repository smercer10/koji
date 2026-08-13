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

### 2026-08-13 — Legal movegen: the Phase 1 perft NPS baseline
- branch:   feat/movegen
- type:     perft (correctness) + bench (the never-regress speed baseline)
- result:   PASS — all 35 perft checks in `testdata/perft.epd` exact, 16,270,939,707 nodes
- bench:    0 (stub — no search exists yet)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    **There is no "before" here.** This is the first movegen, so the numbers below are a
            baseline to defend, not a comparison, and nothing in this entry claims a speedup.

            Correctness. `/code-review high` on the PR found four faults, all in positions the
            engine can be *handed* rather than positions it reaches, which is why 16 billion nodes
            of perft had missed every one. The two that mattered:

              - **En passant did not resolve every check it claimed to.** Bypassing the evasion
                mask is required (see the comment in `generateEnPassant`), but the replacement
                rule was only a slider sweep, so an ep capture was generated while a *knight*
                still checked. `4k3/8/8/3pP3/8/3n4/8/4K3 w - d6 0 1` produced 5 moves instead
                of 4. Perft could not catch this: it needs an ep square and a non-slider check
                and a pawn able to take, and that combination does not occur anywhere in the six
                oracle trees to depth 6 — the counts were byte-identical before and after the fix.
              - **Two hand-writable FENs were memory-unsafe in release builds**, where the asserts
                that catch them in Debug are gone: an ep square with no double push behind it made
                `makeMove` clear an empty square and index `by_type[7]`, one word past a
                `[6]Bitboard`; and a FEN leaving the side that just moved in check (adjacent kings
                included) let movegen capture a king, after which `lsb` of an empty board is
                `@ctz(0)` truncated into a `u6`. Both are now rejected by `movegen.fromFen`, which
                is what every path taking a FEN from outside the program uses.

            `koji epd testdata/perft.epd` reproduces every listed count to depth 6
            (Kiwipete D6 = 8,031,647,685; position 6 D6 = 6,923,051,137) in 71s; `zig build
            test-slow` does the same in ReleaseSafe in 1m34s. Two oracles beyond the node counts:
            a `generateSlow` in movegen.zig that generates every legal *shape* and keeps a move
            only if playing it leaves the king unattacked — sharing nothing with the fast path but
            `sliderAttacksSlow` — checked against `generate` at every node of a depth-2 walk from
            each perft position plus 8 seeded 48-ply random walks from each, and hand-written full
            move lists for the cases perft would only report as a wrong number several plies deep.

            Speed. `koji perft` times itself; figures below are `perf stat -r 5` on the final
            binary, after the review fixes:

              startpos D6  (119,060,324 nodes)  166.1 Mnps   0.7168s +/- 1.52%
              Kiwipete D5  (193,690,690 nodes)  247.8 Mnps   0.7817s +/- 0.92%

            **The never-regress figure is the instruction count, not the NPS.** There is no CPU
            governor control under WSL2, and two 15-run batches of the same binary in different
            machine states differed by ~4% — wider than the ~1.3% spread *within* a batch, so
            wall-clock here cannot resolve anything smaller than about 5%. Instructions are
            deterministic and settle it instead:

              startpos D6  9,454,769,200 instructions   1,864 per generate() call
              Kiwipete D5  9,393,757,922 instructions   2,244 per generate() call

            That is how the review fixes were shown to be free: +0.11% instructions at startpos
            (one AND and a branch on nodes that have an en passant square) and +0.01% at Kiwipete,
            against a 1.5% swing in cycles over the same runs that was purely the machine.

            Both counts use bulk counting (depth 1 returns the move count instead of playing each
            move to count 1), which is standard and changes no node count.

            `perf stat -r 5`, normalised per `generate()` call — that is per *interior* node, which
            is what perft's leaf count is not: 5,072,213 calls for startpos D6, 4,185,553 for
            Kiwipete D5.

                                    startpos D6      Kiwipete D5
              branching factor        23.5             46.3
              cycles / call            636              842
              instructions / call     1864             2244
              IPC                      2.93             2.67
              branch miss rate         0.89%            1.32%
              cache misses / call      0.092            0.129

            **Startpos is the slower position per node, and the counters say why.** Kiwipete emits
            2.0x the moves per call for 1.2x the instructions. Fitting the two points as
            `instructions = fixed + per_move x branching` gives roughly 1,470 fixed and 17 per
            generated move — so at startpos's branching factor about 79% of the work is fixed cost
            paid before a single move is built: the king danger sweep over the whole enemy army,
            `attackersTo` for the checkers, and the sniper loop. Two points fit a line exactly, so
            treat those constants as an estimate, not a measurement — but the direction is not in
            doubt, and it says any future work on this number belongs in the per-node preamble and
            not in the serialisation loops.

            Cache misses are ~0.1 per call against a 64KB `between` + `line` footprint, which
            is already a partial answer to the ablation filed under ROADMAP's candidate ideas:
            those tables are not currently costing anything in misses, so dropping them would have
            to pay for itself in some other way.

            Assembly checked rather than assumed. `between` and `line` are 0x8000 bytes each in
            `.rodata`, and the knight, king and pawn tables are present as contiguous constant
            blobs — recomputed independently in Python and found byte-for-byte in the binary, so
            no comptime table is being rebuilt at runtime. Everything inlines into one 6,040-byte
            `movegen.generate`: 20 `pext` (PEXT path live), 38 `tzcnt` + 34 `blsr` (the popLsb
            serialisation loops), 44 `bt` (the per-move pin tests, one instruction each), 2
            `popcnt` (the double-check test, once per colour specialisation).

            No CPU governor control exists under WSL2, so the wall-clock spread above is a floor
            on what a future A/B can resolve here; the cycle counts are far steadier (+/-0.34% on
            startpos) and are the better instrument for small effects.
