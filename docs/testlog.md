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

### 2026-08-14 — Movegen bounds, and the memset perft was paying at every node
- branch:   fix/movegen-bounds
- type:     perft + bench
- result:   PASS — oracle unchanged, 35/35 checks, 16,270,939,707 nodes; **-39% instructions**
- bench:    0 (stub — no search exists yet)
- machine:  Zen 3, WSL2, ReleaseFast, PEXT path, single thread
- notes:    Two memory-safety bugs out of the Phase 1 review, both driven by nothing but a FEN
            on the command line. `max_moves = 256` rested on the 218-move bound, which is a fact
            about *reachable* positions — and nothing made the parser's output reachable. A
            hand-written 24-queen record generates 271 legal moves: `koji perft 1` on it segfaults
            the shipped build, having written past the end of a stack array. Separately
            `fullmove += 1` was unguarded on a u16 the parser accepts at 65535, while the halfmove
            clock two lines up was already saturating for exactly that reason.

            The fix restores the precondition instead of widening the hole: `fromFen` now rejects
            material no game can produce (a side promotes at most its eight pawns, so every piece
            past the starting complement spends one), and `max_moves` is derived from what that
            check still permits — `8 + 2 + 9*27 + 2*14 + 2*13 + 2*8 = 323`, so 384. The old
            constant was not merely too small, it was justified against the wrong set.

            **The measurement is the interesting part.** 384 alone cost **+19.4%** instructions on
            startpos D6 — far too much for a stack array 256 bytes wider, so the assembly got read:

                sub    $0x328,%rsp
                mov    $0x308,%edx          <- 776 bytes
                call   compiler_rt.memset

            `var list: MoveList = .{}` lowers to a memset of the whole struct at every interior
            node, despite `moves` carrying `undefined` as its field default. `main` was already
            paying it — 520 bytes a node for nothing, since `generate` sets `len` as its first
            statement. Declaring the list `undefined` deletes the call:

                                    startpos D6      Kiwipete D5
              instructions / call     1864 -> 1137     2244 -> 1520
              change                    -39.0%           -32.3%
              Mnps (wall clock)      157 -> 257       259 -> 359

            Instructions are deterministic (+/-0.000001% over 3 runs, two alternating passes);
            the NPS column is directional only, since WSL2 cannot resolve under ~5%. Node counts
            are bit-identical at every depth, so this is pure removed work, not a behaviour change.
            It is also a warning about the idiom rather than about this one line: `= .{}` on any
            struct with a large `undefined` field will do the same in Phase 2's search stack.

            Cost of the other fix: `fullmove` moved into `Undo` so the now-saturating increment is
            reversible, measured at **+0.54%** instructions on its own, and `@sizeOf(Undo)` is
            still 16 — it landed in padding the struct already had. A test pins that size.
