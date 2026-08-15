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
            fixed `default_depth = 6` whatever the clock says, so the two binaries are the same
            player: 16/16 bench positions give an identical `bestmove` at `go depth 6`. Those games
            were measuring time forfeits — 7 of the first 101 ended on the clock, which the faster
            side loses fewer of. **Nothing is SPRT-measurable here until a `go` spends the clock.**

### 2026-08-14 — A `go wtime/btime` budget: soft and hard deadlines
- branch:   feat/clock
- type:     bench + forfeit check
- result:   bench-neutral; 240 games, **zero time forfeits**
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- bench:    22088265 (unchanged)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    No SPRT, and deliberately. Against `main` this would restage the failure recorded
            directly above: a clock-aware binary against a fixed-depth-6 one at 8+0.08 measures
            which side flags, not which plays better. What this branch is worth cannot be read off
            a match with the version that preceded it — it is what makes the *next* box measurable.

            Bench is the gate instead, and it is exact rather than close: 22,088,265 nodes, the same
            figure as the entry above, on both the PEXT and the `-Dcpu=x86_64` magic build. No clock
            is set during `bench`, so both deadlines stay null and the search path is unchanged; any
            movement in that number would have meant the budget leaking into the unclocked path.
            nps 20.1-22.2M, unchanged within WSL2's ~5% floor.

            Forfeit check, 240 self-play games (200, then 40 re-run on the final binary after two
            comments and a parse refactor landed), concurrency 14 on an otherwise idle machine.
            Every game terminated `normal`: 157 mates, 27 threefold, 12 insufficient material, 4
            fifty-move. Elo -15.65 +/- 37.55 is a binary against itself and says only that the
            harness is wired up.

            Move times over 32,675 moves, which is the number that matters here:

              mean                      0.172 s
              p50                       0.112 s
              p95                       0.518 s
              p99                       0.951 s
              max                       1.434 s
              moves over 1.5 s                0

            Against an 8 s starting clock the worst single move took 1.43 s, so nothing came near
            flagging. The hard limit at a full clock is 1.34 s and 57 moves exceeded it: that is the
            design working rather than a leak, since the increment can carry the clock above 8 s
            early and the hard check only fires every `check_interval` nodes. A p50 of 0.112 s
            against an 0.08 s increment says the clock drains slowly, which is what keeps the budget
            shrinking as a game goes on.

            One number to revisit: the soft limit declines the next iteration once elapsed time
            passes half of it, which assumes that iteration costs at least as much as everything
            spent so far. At an effective branching factor of 5.7 (entry above) that assumption is
            conservative, and move ordering will change the branching factor it is guessing about.
            Re-measure then.

### 2026-08-15 — Quiescence search: captures, promotions, and every evasion in check
- branch:   feat/qsearch
- type:     bench + perft + ablation
- result:   bench-measurable; **quiescence is unshippable without victim ordering (296x)**
- bench:    24356801 (was 22088265)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    `testdata/bench.epd`, 16 positions, depth 6, table cleared between positions.

              nodes            22,088,265 -> 24,356,801     +10.3%
              wall clock            1.02 s -> 1.90 s
              Mnps                    21.7 -> 12.9

            Nodes rising is the technique, not a regression: every leaf that was one
            `evaluate` call is now a search. The nps figure is not comparable across this
            commit for the same reason the table commit's was not.

            Bench invariant checked, not assumed: `-Dcpu=x86_64` — no AVX2, magics instead
            of PEXT — gives the same 24,356,801 nodes.

            **The ablation is the entry.** Quiescence was written without any move ordering,
            since ordering is the next roadmap box, and that version cannot be shipped:

                                          no victim sort    with victim sort    ratio
              bench                     7,221,690,584          24,356,801         296x
              Kiwipete to depth 1          40,144,537              22,411       1,791x
              queens-loose to depth 1      13,360,907                 944      14,153x

            One selection sort by captured-piece value, inside quiescence only, no attacker
            term. Ordering cannot change what alpha-beta returns — only how much it visits —
            so the scores are identical either way and this is search shape, not a different
            answer. That is also how the 40M figure was diagnosed as the documented
            no-ordering pathology rather than a bug in the quiescence itself: a fix that only
            permutes moves cannot repair a wrong algorithm. The published diagnostic agrees —
            a healthy quiescence runs ~7:1 q-nodes to main-search nodes and a broken one
            (missing stand-pat, or alpha never raised after it) 100:1+, and 40M at depth 1
            was far outside both.

            Not every position pays. Startpos to depth 6 went **213,714 -> 136,299 nodes**:
            nothing to capture, so quiescence costs almost nothing there, and the leaf scores
            being right tightens the tree instead. The cost is concentrated exactly where the
            captures are.

            **Perft non-regression, and a trap worth recording.** Adding a second generation
            to `movegen.zig` cost **+7.7% instructions on the untouched full-generation path**
            before anything was done about it. Only part of that was the new code: reaching
            the destination mask through a comptime branch instead of a runtime `Ctx` field
            returned 3.7 points (+7.7% -> +4.0%), and dropping the field itself returned
            0.04% more, so both together left most of it unexplained. Building with the
            second instantiation replaced by the first gave *exactly* main's figure, which
            said the remaining code was innocent, and `perf record` said why — on main,
            `generate` is one 76.5% blob with `addPawnMoves`,
            `attackedBy` and `generateEnPassant` inlined into it; the second instantiation
            blew LLVM's inlining budget and pushed all three out of line. Marking those three
            `inline` restored it:

                                    startpos D6      Kiwipete D5
              main            5,767,740,503    6,363,345,710
              branch          5,739,901,617    6,385,591,938
              change                 -0.48%           +0.35%

            Perft nps 284M -> 305M. Instructions repeat to +/-0.00% over 5 runs, so those
            are exact. **The lesson is that a comptime parameter is not free even on the
            branch that does not take it** — it is free in the code it generates and not in
            the inlining budget it consumes, and only a profile distinguishes the two.

            No SPRT yet. The published expectation for an engine at koji's exact maturity —
            quiescence on top of a *material-only* evaluation — is that it measures little or
            nothing, because most of what quiescence protects is invisible to a piece count;
            one author reported exactly no improvement in that state. So the fixed-depth
            horizon check is the correctness signal and the SPRT is a separate question. The
            engine no longer plays Qxd5 into exd5 at depth 1, which it did before this branch.

            **Every number above is post-review, and the first draft of them was wrong.**
            `/code-review` found that horizon nodes were counted twice — `negamax` counted
            the node, then handed the same position to `quiesce`, which counted it again —
            so startpos at depth 1 reported 41 nodes for the 21 positions that exist. That
            is not a cosmetic miscount: `bench` is the OpenBench contract number, `nps` is
            parsed off it, and a `go nodes` budget is spent against it at twice the rate.
            Corrected, bench falls 26,115,877 -> 24,356,801, i.e. 6.7% of the first figure
            was double counting. The ablation's *unordered* column barely moves under the
            same fix (7,223,450,187 -> 7,221,690,584), which is itself informative: with no
            ordering nearly every node is an interior quiescence node, counted once either
            way, and only the horizon entries were ever doubled.

            Turn gate: `zig build test` warm went **0.84s -> 4.33s**. A ply of any fixed-depth
            search test now costs ~10x, which is permanent; two plies of the deep coverage
            moved behind `build_options.slow`, the idiom `perft.zig` already used.
