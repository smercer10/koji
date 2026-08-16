# Roadmap

Seven phases, each with a measurable exit criterion. This file is the backlog — there is
deliberately no `TASKS.md`, because a second list beside this one drifts out of sync within a week.

- *What to build next* → this file.
- *What has already been tried* → [`docs/testlog.md`](docs/testlog.md), including failures.
- *What is in* → `git log`.

---

## Phase 0 — Toolchain

- [x] Install Zig 0.16.0, pinned
- [x] `build.zig` with `run` / `test` / `test-slow` / `bench` steps and a comptime version guard
- [x] `-Dtunables` flag, off by default, so SPSA parameters never appear in a shipped build
- [x] CLI dispatch skeleton: `uci` / `bench` / `perft` / `epd`
- [x] OpenBench-compatible `Makefile`
- [x] `git init`, first commit
- [x] Build fastchess (`tools/fastchess/`, gitignored)

**Exit criterion:** `zig build test` green; `koji bench` prints `N nodes M nps`;
`make EXE=Engine-TEST` produces `Engine-TEST`; a release build's `uci` output lists only real
options. **Met — Phase 0 complete.**

## Phase 1 — Board & movegen

- [x] CI on push and PR: format, `zig build test`, release build, OpenBench `make` contract —
      first, so everything after it is remotely checked
- [x] Protection on `main`: ruleset requiring the `ci` check, linear history, no deletion and
      no force-push. Admin bypasses, so an override stays possible but deliberate
- [x] Bitboards + mailbox
- [x] PEXT magics with a plain-magic fallback for non-PEXT targets
- [x] FEN parsing and output, tolerant of EPD records so the perft oracle parses unchanged
- [x] Move encoding + make/unmake + Zobrist, fixed seed — all three ship together, since until
      a transposition table exists Zobrist's only consumer is make/unmake
- [x] Legal move generation: leapers, pawns, castling, check and pin legality, with the `perft`
      driver and `divide` run over `testdata/perft.epd` from `test` and `test-slow`
- [x] Phase 0 shipped without its phase-boundary code review; everything it wrote folded into
      Phase 1's `/code-review max`, weighted toward `.claude/` where the defects were

**Exit criterion:** perft exact on every position in `testdata/perft.epd`, at every depth that file
carries; instructions per `generate()` call recorded as the never-regress baseline, *not* NPS
(`docs/testlog.md`). **Met — Phase 1 complete.**

## Phase 2 — Search + HCE

- [x] Negamax/alpha-beta, iterative deepening — material-only eval, repetition and fifty-move
      draws, `position`/`go`/`stop` on a search thread, and `bench` over `testdata/bench.epd`
- [x] Transposition table
- [x] A minimal `go wtime/btime` budget — a soft and a hard deadline off the clock
- [x] Quiescence search
- [x] MVV-LVA move ordering, in the main search as well as in quiescence
- [x] SEE, splitting the captures into winning and losing, and not searching the losing ones
      in quiescence
- [x] Killer moves
- [x] PSQT + tapered evaluation
- [x] History heuristic
- [x] Apply `setoption` — `Hash` resizes the table; `Threads` advertises `max 1`, which is what
      koji can do until Phase 5
- [x] Grow the stdin buffer past 8192 bytes, or handle `StreamTooLong`. A long
      `position ... moves ...` line would otherwise kill the engine mid-game

**Exit criterion:** full UCI compliance; wins a match against a known ~1800 reference.
**Met — Phase 2 complete.** 81.0% against Stockfish 18 held at `UCI_Elo 1800`, 100 games at 8+0.08
(81-19-0, +251.89 +/- 85.74, LOS 100%, no timeouts; docs/testlog.md, 2026-08-16).

> Stockfish is GPL-3.0 and is run as a binary opponent under fastchess, so rule 1 holds. **Its
> limiter is not CCRL-calibrated** — "~1800" is Stockfish's own scale, so this is not a rating
> estimate for koji. What it establishes is that koji plays complete, legal, clock-respecting games
> and wins them. The Lichess leg moved to the Phase 6 box below.

> **Decide before the first public build:** release tags `v<major>.<minor>.<patch>` start at this
> phase's exit — the first time anyone else runs the binary — with major = generational change
> (HCE→NNUE), minor = strength release, patch = bugfix. `phase-N` tags stay internal and stop after
> Phase 6. Release step: bump `version` in `src/main.zig` (a source constant — git-derived breaks
> tarball builds), tag to match, and keep a test asserting the two agree.
>
> Also at that point: the PEXT-vs-magic choice is comptime from the build target
> (`src/attacks.zig`), which is exact for native builds but wrong for a distributed generic
> binary — that needs per-target binaries or a one-time-startup CPUID dispatch, and the check must
> be feature flag *plus* family (Excavator–Zen 2 report BMI2 but microcode PEXT).

## Phase 3 — The SPRT era

- [ ] Null-move pruning
- [ ] Late move reductions
- [ ] Aspiration windows
- [ ] Futility pruning / LMP
- [ ] Singular extensions
- [ ] Correction history
- [ ] Time management — best-move stability and score-instability scaling on Phase 2's budget,
      and `Move Overhead` as a UCI option

**Exit criterion:** ~2600–2800. **Every merge from here on is SPRT-gated**, and `docs/testlog.md`
becomes the project's real changelog.

## Phase 4 — NNUE

- [ ] Self-play data generation from the HCE engine
- [ ] Train with `bullet`
- [ ] Incremental accumulator
- [ ] `@Vector` SIMD inference
- [ ] int16/int8 quantisation

**Exit criterion:** net beats HCE by >150 Elo at matched time control; data provenance 100%
self-generated and documented; **`bench` still identical between AVX2 and non-AVX2 builds**
(the bench invariant in CLAUDE.md — decide the integer quantisation scheme at the design step,
not after a mismatch appears).

## Phase 5 — Scaling & tuning

- [ ] Lazy SMP with a lock-free TT
- [ ] SPSA parameter tuning

**Exit criterion:** measured *Elo* gain at 4 threads — not just NPS; SPSA-tuned constants beat
hand-picked ones under SPRT.

## Phase 6 — Competition & contribution

- [ ] Lichess BOT deployment, including the complete game that was Phase 2's third exit condition
- [ ] OpenBench instance
- [ ] Tournament entry
- [ ] Published novelties list with ablation results
- [ ] At least one reusable artefact (tooling or dataset) released openly

**Exit criterion:** rated bot live on Lichess; novelties list published with test results; at least
one reusable artefact contributed back.

Notes that constrain earlier phases:

- **Lichess:** a BOT account must be a *fresh account that has never played a game*, then upgraded
  via the API token, and run through `lichess-bot`. Bots are bound by Lichess ToS.
- **OpenBench contract** (built in at Phase 0): a `Makefile` accepting `EXE=` and `CC=`/`CXX=`, a
  binary named exactly `EXE`, `EVALFILE=` once NNUE lands, `./binary bench` printing
  `<nodes> nodes <nps> nps` (deterministic — the bench invariant in CLAUDE.md), and mandatory
  `Hash` and `Threads` UCI options.
- **Do not solicit rating-list inclusion.** Publish releases and let testers decide. Answer their
  requests quickly when they come.
- **The novelties list starts at Phase 3, not here:** every technique that appears genuinely novel
  is recorded in `docs/testlog.md` with its ablation result as it lands, so the published list is a
  by-product. Re-run ablations periodically — old gains decay as the engine around them changes.

---

## Candidate ideas

Unordered, for the Phase-3+ era when work becomes try-it-and-measure. Moving something here is not a
commitment to implement it.

- Mailbox ablation: drop `Board.mailbox` and probe the type bitboards in `make()` instead;
  `/bench` perft NPS both ways. The hybrid is CPW consensus, not a measurement — all mailbox
  access goes through `put`/`remove`/`movePiece`/`pieceAt`, so the experiment is contained.
- Attack the per-node fixed cost in `movegen.zig` — the largest lever the counters point at, ~79% of
  a `generate()` call at the start position (testlog, 2026-08-13), mostly the king danger sweep over
  the whole enemy army. Skip the sweep when the king has no destination anyway, compute danger
  lazily per candidate king square, or reuse it across a node's siblings.
- Fancy (per-square-sized) attack tables against plain ones: 840KB versus 2.25MB. The size is the
  only half of that trade koji has measured — no speed comparison has ever been run here, and plain
  tables would have to be written to run one, so this is an experiment rather than a switch.
- Drop the 32KB `line` or `between` table from `attacks.zig` and recompute what they serve. Measured
  unpromising already: ~0.1 cache misses per `generate()` call, so 64KB of tables are costing
  nothing to hold. Needs a new argument, not a repeat of this one.
- Split the pawn loop in `movegen.zig` by pin, so `pawns & ~pinned` generates set-wise with no
  per-move pin test and the rare pinned ones are handled separately. Trades a well-predicted branch
  for duplicated pawn logic.
- Set the en passant square only when an enemy pawn can actually capture it. koji follows standard
  FEN and sets it after every double push, which gives two otherwise identical positions different
  Zobrist keys and splits their transposition table entries. Now measurable — the table landed
  2026-08-14 — and it costs standards-conformant FEN output, which is what makes it a trade rather
  than a fix.
- Score moves lazily instead of up front. `Ordered.score` walks the whole list, then `next` walks
  the remainder again, so a node that cuts off after one move pays two passes where the victim-only
  sort it replaced paid one — which is where `bench` lost nps (13.0M -> 10.6M, testlog 2026-08-15)
  while winning on nodes. Two independent halves: fold the scoring into the first `next`, and give
  `score` a comptime `first` so quiescence stops comparing every move against a key that is always
  absent. Node counts cannot move, so this is `/bench`, not an SPRT.
- Drop the LVA half of MVV-LVA and order captures by victim alone. Stockfish removed it in 2015 as
  a simplification that passed SPRT at both time controls, its author putting the whole attacker
  term at half an Elo. koji's own ablation disagrees in *nodes* — the term takes 12.8% off what
  victim-only ordering leaves (testlog, 2026-08-15) — and nodes are not Elo, so this is an SPRT
  at `elo0=-5 elo1=0`.
- Losing captures ahead of the quiets rather than behind them. CPW records both placements as
  common; the case for the other one is that a capture stays tactically loaded even when SEE calls
  it losing, and koji's quiet band was unordered zeros until killers and history landed — so
  "behind the quiets" used to mean behind thirty arbitrary moves. **Unblocked:** history landed
  2026-08-16 and that band now has an order worth ranking against.
- Ablate SEE's ordering split against its quiescence pruning. They shipped under one SPRT, stopped
  inconclusive at +1.94 +/- 4.88 (testlog, 2026-08-15); a 1.56x time-to-depth win returning ~2 Elo
  says one half is giving back most of what the other earns, and nodes cannot say which.
- Index quiet history `[piece][to]` instead of `[side][from][to]`. 768 entries against 8192, so it
  warms faster and holds a tenth of the cache, and it is what most engines index quiet history by
  now — against one new `pieceAt(m.from)` on every quiet of every node, in a branch that currently
  reads no board memory at all. Neither form has been measured here; the classic one shipped
  because it matches the attribution. Node counts move, so this is an SPRT.
- History bonus without the malus half. They shipped under one SPRT because that is how the
  technique is published, but the malus is the least-documented part of it — practitioner reports,
  no published derivation — and it is the half most likely to be doing nothing.
- The classic history ageing cadence: keep the table across a game and halve it per move played,
  rather than clearing it per search. Blocked on a decision, not on code — the classic scheme
  carries state between `bench` positions, which is what the killers reset exists to refuse, so
  taking it would mean changing what `bench` means.
- Raise the default `Hash` above 16MB. Now re-runnable at will, since `setoption` applies it:
  startpos `go depth 11` costs 1.69x the nodes at 1MB that it does at 16MB, while 256MB takes only
  6% more off and is *slower* in wall clock — so 16MB is near the knee at that depth, which was luck
  rather than judgement. Phase 3's pruning changes the tree the curve is measured over, so re-measure
  there before moving the constant, and decide it by SPRT at a long control rather than by nodes.
- Four transposition table entries to a cache line instead of one, replacing the worst of the four.
  A probe already fetches the whole line and uses 16 bytes of it.
- Halve the entry to 8 bytes — a 16-bit key — and check the table's move for pseudo-legality before
  playing it. Twice the entries in the same memory, against the wrong-position hits the check has to
  catch. `isPseudoLegal` does not exist yet and is the risk, not the packing.

From the Phase 2 boundary review (2026-08-16), none taken there: that branch had to stay
bench-neutral to prove its fixes were, and each of these moves the tree or is a refactor of its own.

- Take the stand-pat cutoff **before** `generateNoisy`, not after. Quiescence is the most-visited
  node type and it currently generates a full noisy list — including the king-danger sweep the
  testlog puts at ~79% of a `generate()` call — then discards it whenever the node stands pat at or
  above beta, which is the common case. `movegen.inCheck` first is one `attackersTo` against the
  whole army sweep. Node counts cannot move, so this is `/bench`.
- Try the table's move before generating anything. Most interior nodes are cut-nodes and the table's
  move causes the cutoff most of the time, so the `generate` plus the full scoring pass are thrown
  away at a large fraction of nodes. koji is unusually well placed for it: `Entry.key` is the full
  64 bits, so the move is legal by construction and needs no `isPseudoLegal`.
- Lazy SEE: score captures optimistically and call `see.winning` only when `next` selects one. The
  cost is already measured — 10.65M -> 7.98M nps when SEE landed — and in quiescence the waste is
  structural, since the loop breaks at the first losing capture after scoring all of them.
- `@prefetch` on the TT probe — named on CLAUDE.md's performance surface and used nowhere yet. The
  child's slot is known the moment `makeMove` returns.
- `Ordered.scores` as `i16` rather than `Score`. They are ranks, never mixed with a search score, and
  `next` rescans the tail once per selected move — halving the bytes it streams also halves
  `Ordered` from 2312 to 1544 bytes of stack per node.
- **Stop taking TT cutoffs at PV nodes.** The boundary review fixed only the reporting half of the
  collapsed principal variation; a bound is not a variation, so the line is still short. SPRT.
- Repetition detection inside quiescence — the fifty-move half landed at the boundary, this half
  did not. What it costs, and why that was not obviously worth paying, is at the site in
  `search.zig`.
- Seed the root fallback from the ordering rather than `root.moves[0]`. An abort before the first
  iteration finishes currently answers with whatever movegen emitted first — `go nodes 1` from the
  start position plays `b1a3` — the same hazard the comment on `best_move` warns about inside
  `negamax`, accepted at the root without one.
- Three structural cleanups the review argued for and the close did not take, since each is a
  refactor rather than a fix: pair make/unmake with the repetition push as one `descend`/`ascend`
  operation so the invariant is structural; give `Engine` the transposition table so ownership is
  not split three ways across a stack local, a borrow and `applyOption`; replace the stop flag with
  a search epoch so `clearStop` and its three call sites disappear.
