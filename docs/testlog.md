# Test log

Append-only record of every strength and speed measurement, **including the ones that failed.**

This is the one thing `git log` cannot reconstruct: a failed branch gets deleted and takes its
result with it, so without this file the same dead idea gets retried every few months. A negative
result recorded here is worth as much as a positive one.

Newest entries at the bottom. **Results are append-only**: never revise a number or remove an entry,
and if a result was wrong, append a correction. Cutting prose that only restates `git log` is not a
revision — the numbers are the record, and this file only ever grows, so anything that is not a
result is a tax on every future reader.

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

Keep an entry to what only the measurement can tell you: the numbers, the conditions that make them
comparable to the next ones, and what they imply for what to try next. What the code does, what bugs
were found on the way, and why a design was chosen are in `git log` and in comments at the
implementation site — restating them here is how this file stops being worth reading.

---

## Entries

### 2026-08-10 — Phase 0 scaffolding
- type:     none
- result:   n/a
- bench:    0 (stub — no search exists yet)
- notes:    No engine code, so nothing to measure. Here only so the log starts where the
            repository does.

### 2026-08-12 — Sliding attacks: PEXT with fancy-magic fallback
- branch:   feat/magics
- type:     bench
- result:   finding magics at startup measured and REJECTED
- bench:    0 (stub — no search exists yet)
- machine:  Zen 3, WSL2, ReleaseFast — takes the PEXT path; `-Dcpu=x86_64` takes magics
- notes:    Seeded random-sparse search (Romstad's method), all 128 squares: **2676ms**, 93% of it
            the per-candidate `memset` of the collision table (1.42M trials, 124M subset probes).
            Generation counters instead of clearing: **185ms**. Still pure per-process waste, and
            paid precisely on the old-AMD targets that take the magic path — so the constants are
            hardcoded and the search is test-only.

            Romstad's published "under a second" must be post-folklore-optimisation: the
            naive-but-published form is 15x slower on hardware 20 years newer. Worth remembering
            the next time a wiki or paper quotes a timing.

            Startup A/B (`koji version`, 200 runs, ~1.1ms process baseline): table fill is
            ~0.40ms on either scheme, so init cost is not a reason to prefer one.

### 2026-08-13 — Legal movegen: the Phase 1 perft baseline
- branch:   feat/movegen
- type:     perft + bench
- result:   PASS — `testdata/perft.epd` exact to depth 6, 35/35 checks, 16,270,939,707 nodes
- bench:    0 (stub — no search exists yet)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    First movegen, so this is a baseline to defend, not a comparison.

            `perf stat -r 5`, per `generate()` call — that is per *interior* node, which perft's
            leaf count is not (5,072,213 calls for startpos D6, 4,185,553 for Kiwipete D5):

                                    startpos D6      Kiwipete D5
              branching factor         23.5             46.3
              instructions / call      1864             2244
              cycles / call             636              842
              Mnps                     166.1            247.8

            **The never-regress figure is instructions per call, not NPS.** There is no CPU
            governor control under WSL2: two 15-run batches of the *same* binary differed by ~4%
            across machine states, against ~1.3% within a batch, so wall clock here cannot resolve
            anything under about 5%. Instructions are deterministic (+/-0.00% over 5 runs) and are
            what showed the later en passant fix to be free (+0.11%).

            Kiwipete emits 2.0x the moves per call for 1.2x the instructions. Fitting
            `instructions = fixed + per_move x branching` across the two points gives ~1,470 fixed
            and ~17 per generated move: about 79% of startpos's work is spent before a single move
            is built — the king danger sweep, `attackersTo` for the checkers, the sniper loop. Two
            points fit a line exactly, so treat the constants as an estimate, but the direction is
            not in doubt and it puts any future work on this number in the per-node preamble rather
            than the serialisation loops.

            Cache misses are ~0.1 per call against the 64KB `between` + `line` footprint, so the
            ablation filed under ROADMAP's candidate ideas would have to pay for itself somewhere
            other than misses. Assembly spot-checked: every comptime table lands in `.rodata` and
            the PEXT path is live.

### 2026-08-14 — Movegen bounds: the memset perft was paying at every node
- branch:   fix/movegen-bounds
- type:     bench
- result:   **-39.0% instructions**; supersedes the 2026-08-13 baseline
- bench:    0 (stub — no search exists yet)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    Widening `MoveList` to bound it correctly cost **+19.4%** instructions, which is far
            too much for 256 bytes of stack and is what led here. `var list: MoveList = .{}`
            lowers to a `memset` of the whole struct at every interior node, despite `moves`
            carrying `undefined` as its field default — `main` was already paying 520 bytes a
            node for nothing. Declaring the list `undefined` deletes the call:

                                    startpos D6      Kiwipete D5
              instructions / call     1864 -> 1137     2244 -> 1520
              change                    -39.0%           -32.3%
              Mnps (wall clock)        157 -> 257       259 -> 359

            Two alternating passes; instructions repeat to +/-0.000001% over 3 runs, so the
            comparison is on those. The NPS column is directional only — WSL2 still cannot
            resolve under ~5%. Node counts identical at every depth, so this is removed work
            rather than less work.

            The finding is about the idiom, not the line: `= .{}` on any struct with a large
            `undefined` field does this, and Phase 2's search stack is that shape.

### 2026-08-14 — Negamax + alpha-beta + iterative deepening: the first real bench
- branch:   feat/search
- type:     bench
- result:   baseline — the first entry that is not `bench: 0`
- bench:    70586607
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    First search, so this is a baseline to defend rather than a comparison. Material-only
            eval, no quiescence, no transposition table, and no ordering beyond the previous
            iteration's best move at the root — each of those is a later box, and each is measured
            against this line.

            `testdata/bench.epd`, 16 positions, depth 6, `perf stat -r 5`:

              nodes                    70,586,607   (+/-0.00%, identical all 5 runs)
              instructions         32,117,721,351   (+/-0.00%)
              cycles               10,285,454,822   (+/-1.24%)
              wall clock                  2.307 s   (+/-1.30%)
              Mnps                           30.6

              instructions / node             455
              cycles / node                 145.7      IPC 3.12
              branch misses / node          0.395
              cache misses / node          0.0274

            **Bench invariant checked, not assumed**: `-Dcpu=x86_64` — no AVX2, and the magic path
            instead of PEXT — gives *the same* 70,586,607 nodes at 27.2-27.9 Mnps. Identical work,
            ~12% slower to do it.

            Effective branching factor, startpos, from the `info` lines: 16.2 at depth 4->5, 7.9 at
            5->6, 5.7 at 6->7. With a branching factor near 35 that last figure means alpha-beta is
            already doing most of its job at the root and very little of it inside the tree, which
            is exactly the gap MVV-LVA and killers exist to close. Expect the bench number to
            *fall* sharply when ordering lands, and `bench_depth` to rise to compensate.

            Branch misses at 0.395/node are the number to watch: the move loop is unordered, so
            the cutoff is unpredictable by construction.

            Not an SPRT — there is no previous version that plays, so there is nothing to play
            against. Correctness was gated instead on the minimax-equivalence test (alpha-beta must
            return exactly the score a plain minimax returns over the same tree), deep perft, and
            12 full self-play games at depth 5 through fastchess: all terminated normally, no
            illegal move, no crash, no hang.

### 2026-08-14 — Transposition table: 16MB, direct-mapped, full 64-bit key
- branch:   feat/tt
- type:     bench
- result:   **-68.7% nodes at fixed depth, 2.19x wall clock**
- bench:    22088265 (was 70586607)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    `testdata/bench.epd`, 16 positions, depth 6, table cleared between positions,
            `perf stat -r 5`, ten runs each:

                                        before          after      change
              nodes               70,586,607     22,088,265      -68.7%
              instructions    32,117,721,351 10,568,479,095      -67.1%
              cycles          10,285,454,822  4,513,925,812      -56.1%
              wall clock             2.231 s        1.018 s      -54.4%
              Mnps                      31.6           21.7      -31.3%

              instructions / node        455            478       +5.2%
              cycles / node            141.4          204.4      +44.6%
              IPC                       3.22           2.34
              branch misses / node     0.394          0.541      +37.3%
              cache misses / node     0.0238         0.3084       x12.9

            Node counts identical every run, instructions +/-0.00%, wall clock +/-1.6%. The node
            count is what moved and the per-node cost got worse: 3.2x less work at 45% more cycles
            each, a probe costing a cache miss roughly every third node. Nps falling is therefore
            expected rather than a regression to chase — and it means nps is no longer comparable
            across this commit, only nodes-to-depth is.

            Bench invariant checked, not assumed: `-Dcpu=x86_64` — no AVX2, magics instead of
            PEXT — gives the same 22,088,265 nodes at 20.8-21.0 Mnps.

            **The depth-6 bench understates this badly.** Startpos, nodes to reach each depth:

              depth       base         with TT     ratio
                  5     35,531          26,088      1.36
                  6    280,302         213,714      1.31
                  7  1,583,174         730,972      2.17
                  8 22,970,811       3,892,588      5.90
                  9 98,149,412      15,492,824      6.34

            1.00x at depth 3 against 6.34x at depth 9: transpositions are what deepens, so the
            bench is calibrated well below where the engine plays. Effective branching factor at
            8->9 falls 4.27 -> 3.98, at 7->8 14.5 -> 5.3. Raising `bench_depth` once ordering
            lands would make it a better predictor of Elo, not merely a bigger number.

            **Why there is no Elo number.** An SPRT was started and deliberately stopped at 90
            games: elo0=0 elo1=5 alpha=beta=0.05, 8+0.08, UHO_Lichess_4852_v1.epd, LLR 0.24,
            +42.68 +/- 43.90, 29-18-43. koji parses `wtime`/`btime` and ignores them, searching a
            fixed `default_depth = 6` whatever the clock says, so the two binaries are **the same
            player** — 16/16 bench positions give an identical `bestmove` at `go depth 6`. What
            those games measured was time forfeits, 7 of the first 101 ending on the clock, which
            the faster side loses fewer of. Real at this TC, wrong mechanism, and an understatement
            besides: the 6.3x at depth 9 buys nothing until the search can spend it.

            **No SPRT here means anything until `go wtime/btime` lands**, which is why that box
            moved to the front of Phase 2. The harness is fine and set up: fastchess alpha 1.8.2,
            book checksum-verified, 14 of 16 threads.
