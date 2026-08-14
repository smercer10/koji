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
      no force-push. Repository admin bypasses, so an override is possible but deliberate —
      and since agent sessions push with that same token, the ruleset stops accidents, not us
- [x] Bitboards + mailbox
- [x] PEXT magics with a plain-magic fallback for non-PEXT targets
- [x] FEN parsing and output, tolerant of EPD records so the perft oracle parses unchanged
- [x] Move encoding + make/unmake + Zobrist, fixed seed — all three ship together. A `Move` with
      no consumer is untestable, and before a transposition table exists Zobrist's only consumer is
      make/unmake: splitting it out would mean a branch whose entire test surface is the previous
      branch's code, plus a second pass threading xors back through every arm of make/unmake
- [x] Legal move generation: leapers, pawns, castling, check and pin legality, with the `perft`
      driver and `divide` run over `testdata/perft.epd` from `test` and `test-slow`
- [x] Phase 0 shipped without its phase-boundary code review. Include everything it
      wrote in Phase 1's `/code-review max`: `src/main.zig`, `build.zig`, `Makefile`,
      `.claude/hooks/` and `.claude/settings.json` — weight the review toward `.claude/`,
      where every real defect so far has been found (settings.json at Phase 0; guard.sh
      bypasses and an unresolvable /sprt command in the pre-Phase-1 review)

**Exit criterion:** perft exact on every position in `testdata/perft.epd`, at every depth that file
carries; instructions per `generate()` call recorded as the never-regress baseline, *not* NPS
(`docs/testlog.md`). **Met — Phase 1 complete.**

## Phase 2 — Search + HCE

- [x] Negamax/alpha-beta, iterative deepening — material-only eval, repetition and fifty-move
      draws, `position`/`go`/`stop` on a search thread, and `testdata/bench.epd` behind a real
      `bench`
- [x] Transposition table
- [x] A minimal `go wtime/btime` budget — a soft and a hard deadline off the clock
- [ ] Quiescence search
- [ ] MVV-LVA + SEE move ordering, killers, history
- [ ] PSQT + tapered evaluation
- [ ] Apply `setoption` — `Hash` and `Threads` are advertised but currently inert
- [x] Grow the stdin buffer past 8192 bytes, or handle `StreamTooLong`. A long
      `position ... moves ...` line would otherwise kill the engine mid-game

**Exit criterion:** full UCI compliance; wins a match against a known ~1800 reference; plays a
complete game on Lichess.

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

- [ ] Lichess BOT deployment
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
- Four transposition table entries to a cache line instead of one, replacing the worst of the four.
  A probe already fetches the whole line and uses 16 bytes of it.
- Halve the entry to 8 bytes — a 16-bit key — and check the table's move for pseudo-legality before
  playing it. Twice the entries in the same memory, against the wrong-position hits the check has to
  catch. `isPseudoLegal` does not exist yet and is the risk, not the packing.
