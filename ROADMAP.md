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
- [x] Legal move generation — leapers, pawns, castling, check and pin legality — with the `perft`
      driver and `divide`, run over `testdata/perft.epd` from `test` and `test-slow`. One item,
      because perft is movegen's only real test: the workflow says write that test first, so
      splitting them would have meant merging a generator nothing checked, then debugging the
      divergence it caused without the `divide` built to localise it
- [ ] Phase 0 shipped without its phase-boundary code review. Include everything it
      wrote in Phase 1's `/code-review max`: `src/main.zig`, `build.zig`, `Makefile`,
      `.claude/hooks/` and `.claude/settings.json` — weight the review toward `.claude/`,
      where every real defect so far has been found (settings.json at Phase 0; guard.sh
      bypasses and an unresolvable /sprt command in the pre-Phase-1 review)

**Exit criterion:** perft exact on all standard positions to depth ≥6, checked against
`testdata/perft.epd` (the oracle — node counts transcribed from CPW, not from memory); perft NPS
recorded as the never-regress baseline.

## Phase 2 — Search + HCE

- [ ] Negamax/alpha-beta, iterative deepening
- [ ] Transposition table
- [ ] Quiescence search
- [ ] MVV-LVA + SEE move ordering, killers, history
- [ ] PSQT + tapered evaluation
- [ ] Apply `setoption` — `Hash` and `Threads` are advertised but currently inert
- [ ] Grow the stdin buffer past 8192 bytes, or handle `StreamTooLong`. A long
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
- [ ] Time management

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
- Attack the per-node fixed cost in `movegen.zig`, which the Phase 1 baseline measured at roughly
  1,470 of the ~1,860 instructions a `generate()` call spends at the start position — the king
  danger sweep recomputes the entire enemy army's attack set every node, before a single move is
  built. Options: skip the sweep when the king has no legal destination anyway, compute danger
  lazily per candidate king square (≤8 squares, and most nodes need none of them), or cache the
  sweep across the sibling moves of a node. This is the single largest lever on perft NPS that the
  counters point at, and none of it is worth doing before there is a search to measure it against.
- Drop the 32KB `line` table from `attacks.zig` and confine a pinned piece some other way, or drop
  the 32KB `between` table and derive the check-evasion mask from two magic lookups instead. Both
  are read only through the king's row, so 64KB of tables serve one row each per node. The Phase 1
  baseline measured ~0.1 cache misses per `generate()` call, so they are *not* currently costing
  misses and this now looks unpromising — recorded because the reasoning that motivated it was
  wrong, not because the idea is good. CPW's only data point is a single unverified forum anecdote
  about a closed engine, which is not evidence either.
- Split the pawn loop in `movegen.zig` by pin: pinned pawns are rare, so the per-move pin test in
  `addPawnMoves` is a branch almost always taken the same way. Generating `pawns & ~pinned` set-wise
  with no test at all, and looping over the few pinned ones separately, trades a branch for
  duplicated pawn logic — only worth it if it measures.
- Set the en passant square only when an enemy pawn can actually capture it. koji follows standard
  FEN and sets it after every double push, which gives two otherwise identical positions different
  Zobrist keys and splits their transposition table entries. Node counts are unaffected either way,
  so this is unmeasurable until a TT exists — and it costs standards-conformant FEN output, which is
  what makes it a trade rather than a fix.
