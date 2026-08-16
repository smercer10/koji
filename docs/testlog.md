# Test log

Append-only record of every strength and speed measurement, **including the ones that failed.**

This is the one thing `git log` cannot reconstruct: a failed branch gets deleted and takes its
result with it, so without this file the same dead idea gets retried every few months. A negative
result recorded here is worth as much as a positive one.

Newest entries at the bottom. **Results are append-only**: never revise a number, and never remove
an entry because its result is inconvenient — if a result was wrong, append a correction. What that
protects is the record, not the page count. Removing an entry that fails the admission bar below is
not a revision, and neither is cutting prose that only restates `git log`; the numbers are the
record, and anything that is not one is a tax on every future reader.

## What earns an entry

**Most branches get no entry, and that is the normal outcome.** A compliance box, a refactor or a
bug fix is not an experiment. An entry is for a result that would otherwise be *lost*, and that a
future session would waste real work rediscovering — so before appending, one of these must hold:

- **A failure, a rejection, or an approach abandoned.** The branch is about to be deleted and takes
  its result with it. This is the case the file exists for, and it is the one never to skip.
- **Any SPRT — passed, failed or stopped.** Elo appears in no other file, and each figure sets the
  bar the next change of that kind has to beat.
- **A merge made without a passing SPRT.** `git log` shows the merge and never the exception.
- **A baseline or an ablation** that later work is measured against.
- **A trap in how a measurement was taken** that would otherwise produce plausible wrong numbers
  again.

These do not earn one on their own:

- **A bench that only confirms nothing moved.** The commit's `Bench:` line already asserts it and CI
  already checks it.
- **A number anyone can regenerate from `main` on demand.** Record *what to re-run* as a ROADMAP
  candidate idea; the value itself is not evidence, it is a lookup.
- **A result whose conclusion is "carry on unchanged."**
- **Anything a commit message, a comment at the implementation site, or a skill already holds.** One
  rule, one home.

An entry that fails this bar is not neutral — it dilutes the ones that pass, and every future reader
pays for it.

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

### 2026-08-15 — Quiescence search
- branch:   feat/qsearch
- type:     SPRT + bench + perft
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **PASS** — H1 accepted
- LLR:      2.95 (-2.94, 2.94)
- Elo:      +21.27 +/- 9.83 (nElo +27.63 +/- 12.73, LOS 100.00%)
- games:    2862 (971-796-1095), 53.06%, draw ratio 34.17%, Ptnml [107,298,489,387,150]
- bench:    24356801 (was 22088265)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path; SPRT at concurrency 14, 1t/16MB per engine
- notes:    The first SPRT this project could run: the two entries above declined one because
            the binaries were the same player at fixed depth, then because a clock-aware
            build against a fixed-depth one measures which side flags. 1h32m, 31 games/min.

            **Do not read an early SPRT.** This sat at 49.5% for ~500 games, LLR in
            (-0.19, +0.09), and was called a dead heat before the sample justified it. At
            elo0=0/elo1=5 a few hundred games cannot separate +20 from 0.

            `testdata/bench.epd`, 16 positions, depth 6, table cleared between positions:

                                    before          after      change
              nodes             22,088,265     24,356,801      +10.3%
              wall clock            1.02 s         1.90 s
              Mnps                    21.7           12.9

            Nodes rising is the technique: every leaf that was one `evaluate` call is now a
            search, so nps is not comparable across this commit, only nodes-to-depth.
            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same 24,356,801.

            **Quiescence is unshippable without victim ordering.** Written first with none,
            since ordering is the next box:

                                          no victim sort    with victim sort    ratio
              bench                     7,221,690,584          24,356,801         296x
              Kiwipete to depth 1          40,144,537              22,411       1,791x
              queens-loose to depth 1      13,360,907                 944      14,153x

            Ordering cannot change what alpha-beta returns, only how much it visits, so the
            scores are identical either way — this is search shape, not a wrong answer.
            Not every position pays: startpos to depth 6 *fell* 213,714 -> 136,299.

            Perft, `perf stat -r 5`, +/-0.00%:

                                    startpos D6      Kiwipete D5
              main            5,767,740,503    6,363,345,710
              branch          5,739,901,633    6,385,591,938
              change                 -0.48%           +0.35%

            That parity was not free. **A comptime parameter costs inlining budget even on
            the branch that does not take it**: the second generation cost +7.7% before any
            of it ran, and the masks and the struct field — both obvious suspects — returned
            3.7 points and 0.04%. A profile found the rest, three helpers pushed out of a
            `generate` that had been one 76.5% blob. Only a profile separates the two.

            **+21 Elo is a floor.** One error class removed while the dominant one — a
            material count blind to king safety and activity — is untouched, and depth paid
            for it (nps 21.7 -> 12.9M). Both reverse as the engine grows: re-run as an
            ablation once ordering and PSQT land.

### 2026-08-15 — MVV-LVA move ordering
- branch:   feat/mvv-lva
- type:     SPRT + bench
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **PASS** — H1 accepted
- LLR:      2.95 (-2.94, 2.94)
- Elo:      +83.35 +/- 15.30 (nElo +155.34 +/- 27.44, LOS 100.00%)
- games:    616 (166-21-429), 61.77%, draw ratio 61.36%, Ptnml [1,5,189,74,39]
- bench:    4737990 (was 24356801)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path; SPRT at concurrency 14, 1t/16MB per engine
- notes:    13 minutes and 616 games, against 1h32m and 2862 for quiescence. The bound is
            hit this fast because the effect is large, not because anything was read
            early — PairsRatio 18.83 on 616 games is a different regime from the +21 Elo
            that needed 2862.

            `testdata/bench.epd`, 16 positions, depth 6, table cleared between positions:

                                              nodes      change
              main                       24,356,801
              main-search ordering only   4,975,610      -79.6%
              shipped, both nodes         4,737,990      -80.5%
              rank MVV, no attacker term  5,431,917      -77.7%

            Row 2 leaves quiescence on the victim-only sort it already had, so ordering
            the main search accounts for 79.6 of the 80.5 points and quiescence moving
            onto the shared scorer for the last 0.9. Stated against its own row instead,
            quiescence takes 4.8% off what the main search alone had left.

            `perf stat -r 5`: 1.8826s +/- 0.07% -> 0.4547s +/- 0.56%, a 4.14x speedup on
            13.0M -> 10.6M nps. The nps is down because the scoring pass is paid at every
            node; the node count is what carries the win.

            **The attacker term takes 12.8% off victim-only ordering** (row 4 to row 3),
            which is not what the published Elo evidence predicts: Stockfish removed LVA
            in 2015 as a simplification that passed SPRT at both time controls, its author
            estimating the whole term at half an Elo. Nodes are not Elo and this branch
            does not separate them — dropping LVA is on the candidate list as its own
            `elo0=-5 elo1=0` test, and that test is the only thing that settles it.

            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same 4,737,990.

            **The next ordering box is measured against this, not against `main`.** An
            80% node cut is most of what ordering has to give at this eval; killers and
            history land in the quiet band, which is untouched here and where a
            material-only eval has least to say.

### 2026-08-15 — SEE: winning/losing split, and quiescence pruning
- branch:   feat/see
- type:     SPRT + bench
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **inconclusive** — stopped by hand at 5372 games, neither bound reached
- LLR:      0.27 (-2.94, 2.94), having peaked at 1.14 around 3700 games
- Elo:      +1.94 +/- 4.88 (nElo +3.70 +/- 9.29, LOS 78.23%)
- games:    5372 (849-819-3704), 50.28%, draw ratio 67.68%, Ptnml [98,325,1818,339,106]
- bench:    2188249 (was 4737990)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path; SPRT at concurrency 14, 1t/16MB per engine
- notes:    Stopped, not failed. The estimate settled near +2 Elo — inside the
            indifference region, where this bound pair has least power. 5372 games
            bought 0.27 of the 2.94 needed and the LLR had already been to 1.14 and
            back, so the answer needs a different instrument, not more games.

            `testdata/bench.epd`, 16 positions, depth 6, table cleared between positions:

                                          nodes      change
              main                    4,737,990
              ordering split only     3,517,934      -25.8%
              split + qsearch prune   2,188,249      -53.8%

            The split is worth more than the published accounts imply — they put most
            of SEE's effect on the pruning — and pruning still takes 37.8% off what the
            split leaves.

            `perf stat -r 5`: 0.4525s +/- 0.38% -> 0.2897s +/- 0.51%, 1.56x to the same
            depth, on 10.65M -> 7.98M nps and 5.16G -> 3.20G instructions. SEE is paid
            per capture per node, which is where the nps goes.

            **A 54% node cut returning ~2 Elo is the result worth recording.** The
            exchange logic was checked rather than suspected: `/code-review high` ran
            `see.value` against an independently written recursive formulation over
            ~500,000 captures from random playouts, zero mismatches. The live suspect is
            placement — losing captures rank *below* the quiet band, and that band is
            unordered zeros until killers and history land, so a losing capture is
            searched after ~30 arbitrary quiets. CPW records the other placement as
            equally common, and it is the cheapest thing to vary next.

            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same 2,188,249.

            **Merged on the efficiency evidence without a passing SPRT** — a deliberate
            exception, recorded here because `git log` will not show one. The pieces
            that would decide it are not in place yet: quiescence carries the tactics
            in a material-only eval, and the quiet band it ranks against is unordered
            until killers and history land. Re-run once those and PSQT exist.

### 2026-08-16 — Killer moves: correct, and a time-to-depth regression at this eval
- branch:   feat/killers
- type:     bench
- result:   **FAIL** — -1.30% nodes bought at +2.01% wall clock. No SPRT run. Merged
            anyway, deliberately; the reason is at the end of this entry.
- bench:    2159832 (was 2188249)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    Two slots per ply, stored on a beta cutoff by a quiet move, ranked between
            the winning captures and the quiet band. `testdata/bench.epd`, 16 positions,
            depth 6, table cleared between positions, `perf stat -r 5`:

                                            nodes    instructions      wall clock
              main                      2,188,249   3,209,274,976   0.29694 s +/- 0.59%
              killer compares only      2,188,249   3,249,659,119   0.30137 s +/- 0.80%
              killers live              2,159,832   3,268,091,863   0.30290 s +/- 0.40%

            The middle row is the ablation that decides it: the killer band left in the
            scorer with the slots never filled, so the two comparisons per quiet move are
            paid and nothing can match. **They cost +1.49% wall clock on their own — more
            than the entire 1.30% node win the filled slots then buy.** The mechanism is
            not merely unprofitable, it is underwater before it does anything.

            Isolated, no table, Kiwipete, killer band ablated against live:

                        depth 5        depth 6         depth 7
              off      134,925        760,786       3,438,106
              on       134,892        760,454       3,429,345
              change     -0.02%         -0.04%          -0.25%

            **The cause is the evaluation, not the implementation.** `evaluate` is material
            only, so every quiet move at a node returns the same static score and a fail-high
            has to come from a tactic — which means from a capture. Killers order the quiet
            band; at this eval that band almost never produces the cutoff, so there is nearly
            nothing for them to be right about. Instrumenting cutoffs agreed directionally
            (quiet moves cause a low single-digit percentage of cutoffs, and a killer causes
            almost every one of those) but the per-depth counters were not self-consistent
            and are not quoted as a result here.

            Not a defect hunt: the mechanism is covered by unit tests, so what follows is a
            statement about the evaluation and not about the implementation.

            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same 2,159,832.

            **Merged despite the regression** — a deliberate exception, recorded here because
            `git log` will not show one, and the second in two boxes after SEE. The judgement is
            that the mechanism is correct and its cost is paid to a scoring pass that is already
            on the candidate list to be made lazy, so the branch is kept as working code rather
            than re-derived later. It is a 2% time-to-depth regression on `main` until then, and
            nothing here pretends otherwise.

            **Re-measure after PSQT + tapered evaluation.** This is the same finding the SEE
            entry ends on one box earlier, now with an ablation under it: two ordering boxes in
            a row have returned nearly nothing because the thing they order is invisible to a
            material-only eval. PSQT moves ahead of history in the roadmap for that reason. If
            the re-measurement still shows a loss, the honest move is to take killers back out.

### 2026-08-16 — PSQT and tapered evaluation
- branch:   feat/psqt
- type:     SPRT
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **PASS**
- LLR:      2.96 (-2.94, 2.94)
- Elo:      +676.08 +/- 157.59
- games:    300 (292-4-4)
- bench:    3006951 (was 2159832)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    **Read the Elo as "an evaluation beats no evaluation", not as a claim about these
            tables.** The baseline could not tell one quiet move from another, so almost any
            positional signal would have passed; +676 sets no bar for what replaces it. The
            tables are generated from 15 constants and have never been tuned.

            `perf stat -r 5`, `testdata/bench.epd`, 16 positions, depth 6:

                                nodes     instructions   insn/node      wall clock
              main          2,159,832    3,257,787,088        1508   0.28834 s +/- 1.28%
              psqt          3,006,951    4,414,674,266        1468   0.39782 s +/- 1.07%
              change          +39.22%          +35.51%      -2.67%         +37.97%

            **Instructions per node went down.** Folding material into the tables makes
            `evaluate` one interpolation where it was twelve popcounts, which more than pays
            for the extra lookup `put`/`remove`/`movePiece` now do — so the accumulator was
            worth building up front rather than deferring. The whole wall-clock cost is the
            39% wider tree, which is what a discriminating eval does at fixed depth, and it is
            bought back many times over by the Elo.

            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same 3,006,951.

            **The killers question from the entry above is answered.** That entry's node bound
            measured a different engine once the leaves changed value, so it had to be
            re-derived; doing so re-ran the ablation. Kiwipete, depth 7, no table:

                              killers off      killers on      change
              material only     3,438,106       3,429,345      -0.25%
              with PSQT         3,849,447       3,799,071      -1.31%

            Five times the node reduction from the same code. The diagnosis in that entry was
            right — killers were never the problem, the eval they ordered against was — and
            the honest move it proposed, taking them back out, is off the table.

            Three parked experiments are now worth running, and were not before: the SEE
            ordering-versus-pruning ablation, losing captures ahead of the quiets rather than
            behind them, and the LVA ablation. All three were held back for the same reason.

### 2026-08-16 — History heuristic, with malus
- branch:   feat/history
- type:     SPRT
- bounds:   elo0=0 elo1=5 alpha=0.05 beta=0.05
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **PASS**
- LLR:      2.95 (-2.94, 2.94)
- Elo:      +21.12 +/- 9.61 (nElo +28.71 +/- 13.02, LOS 100%)
- games:    2734 (1084-918-732), Ptnml(0-2) [99, 214, 630, 270, 154]
- bench:    2679414 (was 3006951)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread, 14 concurrency
- notes:    The first ordering box to pay at fixed depth. `perf stat -r 5`,
            `testdata/bench.epd`, 16 positions, depth 6, taken before the SPRT
            started and with nothing else on the machine:

                                nodes     instructions   insn/node      wall clock
              main          3,006,951    4,393,935,787        1461   0.40277 s +/- 0.85%
              history       2,679,414    4,113,841,193        1535   0.38697 s +/- 0.23%
              change          -10.89%           -6.38%      +5.06%          -3.92%

            5% more work per node — one table read in the quiet branch plus the
            update at each cutoff — against a tree 10.9% smaller. SEE and killers
            both cost time-to-depth for their node reduction; this one does not.

            **The ablation is clean in the strong sense, and that is the number
            worth keeping.** With the history band cut out of the scorer and
            nothing else changed, bench returns exactly main's 3,006,951 and
            kiwipete depth 7 returns exactly 3,799,071 — the figure the killers
            test already carried as its live value. So the wiring is provably
            behaviour-neutral when the table is zero, and the whole delta is the
            ordering rather than an incidental change to the tree.

            **Elo per node is much worse than PSQT's, as expected.** +676 came
            from an engine that could not tell two quiet moves apart; +21 is what
            a real ordering improvement is worth on top of a working evaluation.
            This is the first number on this branch that sets a usable bar for
            what a future ordering change has to beat.

            Kiwipete depth 7 moved only 3,799,071 -> 3,789,513, a 0.25% node
            reduction against bench's 10.89%. One position at one depth is not
            evidence against the other measurement, but it is a reminder that the
            search test's bound is a regression guard and not a result.

            Invariant checked, not assumed: `-Dcpu=x86_64` gives the same
            2,679,414.

            Three constants (`history_max`, `history_slope`, `history_bonus_max`)
            were picked, not tuned, and no variant was tried — the sources are
            explicit that nobody can justify a particular set. Nothing here says
            these are good values, only that they beat having none.

### 2026-08-16 — Phase 2 boundary review: the killer ablation, re-measured
- branch:   chore/close-phase2
- type:     ablation, and three measurement traps
- bench:    2679414 (unchanged, and identical on `-Dcpu=x86_64`)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    **Killers now buy 0.04% of the tree, not 1.31%.** Kiwipete depth 7,
            table off, killer band cut out of the scorer and nothing else
            changed:

                              nodes      margin over live
              killers live  3,789,513                   —
              ablated       3,791,023               0.04%

            The figure when killers merged was 3,849,447 ablated against
            3,799,071 live — 1.31%. History landed between the two and has
            absorbed almost all of it. **This is one position at one depth and
            not a verdict on the technique**, which passed its own SPRT at
            +9.61 and was measured over 16 positions; it is recorded because the
            in-tree bound is measured here, and because it sets the bar for what
            a future ordering change has to beat on this position.

            **The bound had stopped guarding anything.** At 3,849,447 it sat
            1.6% *above* the current ablated figure, so `storeKiller` could be
            deleted from `negamax` and `zig build test` stayed green. It was
            also strictly dominated: the history test asserts < 3,799,071 on the
            same position at the same depth, a tighter bound the suite already
            checks. Now 3,791,023.

            Two more guards were asserting nothing, both found by mutation
            rather than by reading:

            - **No test required a principal variation longer than one move.**
              Replacing `updatePv`'s tail copy with `pv_len[ply] = 1` — every
              reported line truncated to its first move — left the whole gate
              green. The three PV assertions were `pv.len > 0`, `pv_len[0] == 1`
              on a mate in one, and `pv_len[0] <= depth`, which is the wrong
              direction: 1 <= depth always holds. And the PV *was* collapsing:
              a TT bound cutoff returned before `updatePv`, so with a warm table
              kiwipete `go depth 3` reported `pv d5e6` and nothing more.
            - **Both mate-distance tests compared a value with itself.** The two
              FENs differed only by a white pawn on h2 versus h3, which Ra1a8#
              does not care about, so both scored `mate 1` and the assertion was
              `31999 >= 31999`. An inverted ply fold passes that. They now use a
              genuine mate-in-1 against a mate-in-2.

            **Trap worth keeping: a node-count bound measured against an
            ablation decays silently.** Every one of these was correct when
            written and was invalidated by a later change to the tree, with no
            signal at the moment it stopped meaning anything. Three bounds in
            this file have now needed recalibration for exactly this reason. A
            bound is only one-sided with respect to the engine that produced it.

            The nine remaining review findings that move the tree or the clock
            are ROADMAP candidates, not changes made here — the close is a chore
            commit and bench had to stay at 2679414 to prove it.

### 2026-08-16 — Phase 2 exit match, and the regression it caught
- branch:   fix/phase2-review
- type:     fixed-opponent match (exit criterion), and a green-suite regression
- opponent: Stockfish 18, `UCI_LimitStrength=true UCI_Elo=1800`, GPL-3.0
- TC:       8+0.08
- book:     UHO_Lichess_4852_v1.epd
- result:   **81.0%** — 100 games, 81-19-0, +251.89 +/- 85.74 Elo
            (nElo +290.14 +/- 68.10, LOS 100%), Ptnml(0-2) [1, 0, 17, 0, 32]
- bench:    2679414 (unchanged)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread, 4 concurrency
- notes:    Stockfish's strength limiter is not calibrated against CCRL, so
            "1800" is its own scale and this number is **not** a rating estimate
            for koji. What the criterion establishes is that koji plays complete,
            legal, clock-respecting games and wins them decisively.

            **The first run of this match scored 0.0% — 400 games, 400 losses,
            400 timeouts — and every other gate in the project was green.**
            `zig build test` (161 tests), `zig fmt --check`, `guard_test` 74/74,
            `bench` bit-identical at 2,679,414 on both the PEXT and
            `-Dcpu=x86_64` builds, and CI on the PR. The bug was introduced by
            this very branch, in the fix for a review finding about `ucinewgame`
            and `position` emitting an unrequested `bestmove`:

                cancelSearch tested `e.thread != null`
                -> but only a join clears `thread`
                -> so a search that had finished and already printed still
                   matched, and the `position` between two moves armed the
                   suppression flag against it
                -> which then swallowed the *next* search's bestmove
                -> engine silent from move two of every game

            Localised in one run by playing `main`'s binary against the same
            opponent: 8-1-1 with no timeouts, against 0-400 for the branch — ten
            minutes, after two hours spent re-reading time-management code that
            was never involved.

            **Trap worth keeping: a UCI state-machine bug is invisible to every
            gate that does not play a game.** The failure mode is an engine that
            says nothing, and nothing in a unit suite waits for it to speak.
            `bench` cannot see it either — it never issues a second `go` against
            a live thread, which is the state the bug needed. The smoke match
            this produced is in CLAUDE.md, Workflow.

            The regression test added with the fix drives the real state machine
            — spawn, let it finish, cancel through it, assert nothing is armed
            and the next search still answers — rather than setting the flag by
            hand, since the defect was entirely in which predicate decides a
            search is live.
