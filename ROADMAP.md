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

- [ ] Bitboards + mailbox
- [ ] PEXT magics with a plain-magic fallback for non-PEXT targets
- [ ] make/unmake
- [ ] Zobrist hashing, fixed seed
- [ ] FEN parsing and output
- [ ] Phase 0 shipped without its phase-boundary code review. Include everything it
      wrote in Phase 1's `/code-review max`: `src/main.zig`, `build.zig`, `Makefile`,
      `.claude/hooks/` and `.claude/settings.json` — the last two were hand-tested
      only, and settings.json is where both of this phase's real defects were found

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

> **Tagging and versions — for consideration, decide before the first public build.** `phase-N` tags
> mark internal milestones and stop after Phase 6. Release tags are a separate namespace and start
> *here*, not at Phase 6: the exit criterion above is the first time anyone else runs the binary,
> rating lists identify engines by version string, and `id name koji <version>` is what a tester
> reports. Untagged commits behind a public appearance are unciteable later.
>
> Proposed scheme `v<major>.<minor>.<patch>` — major for a generational change (HCE→NNUE, a new NNUE
> architecture), minor for a strength release, patch for bugfixes. Deliberately not semver: there is
> no API, so "breaking" has nothing to attach to.
>
> Release step: bump `version` in `src/main.zig`, then tag to match. Keep it a source constant rather
> than deriving it from git, which breaks building from a tarball and buys nothing here. Worth a test
> asserting the constant and the tag agree — a version string that disagrees with its tag is the kind
> of sloppiness testers notice and remember.

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
self-generated and documented; **`bench` still identical between AVX2 and non-AVX2 builds**.

> **The determinism trap — decide this at Phase 4's design step, not after a mismatch appears.**
> `-Dcpu=native` is right for local speed, but a native build and a portable build must still
> produce the *same node count*: OpenBench requires cross-machine determinism, and SPRT comparisons
> are worthless without it. Integer inference preserves this; floating-point accumulation does not,
> because SIMD width changes the summation order. Quantise to int16/int8 and keep every eval path
> integer.

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
- **OpenBench compatibility** is built in at Phase 0 because it is nearly free then and annoying to
  retrofit: a `Makefile` accepting `EXE=` and `CC=`/`CXX=`, a binary named exactly `EXE`, `EVALFILE=`
  once NNUE lands, `./binary bench` printing `<nodes> nodes <nps> nps` bit-deterministically across
  runs and machines, and mandatory `Hash` and `Threads` UCI options.
- **Do not solicit rating-list inclusion.** Publish releases and let testers decide. Answer their
  requests quickly when they come.

---

## Give-back is not a Phase 6 activity

It starts as soon as there is anything to give. From **Phase 3**, every technique that appears
genuinely novel is recorded in `docs/testlog.md` with its ablation result, so the published list is
a by-product of ordinary work rather than a retrospective scramble.

Related discipline: **re-run ablations periodically.** A technique that gained 8 Elo two years and
forty patches ago may be worth nothing today, and re-testing is the only way to find out.

## Candidate ideas

Unordered, for the Phase-3+ era when work becomes try-it-and-measure. Moving something here is not a
commitment to implement it.

*(empty)*
