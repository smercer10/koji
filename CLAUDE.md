# koji — UCI chess engine in Zig 0.16. GPL-3.0.

## Ethos
- Performance over everything. Simple beats clever.
- Benchmark, never assume. No performance claim without a measurement behind it.
- No external dependency without a written justification. Currently zero, and that is the target.
- Original code only. Elo is the only opinion that counts.

## Commands
`zig build` (ReleaseFast) · `zig build test` (unit + shallow perft, warm <1s — the turn gate) ·
`zig build test-slow` (deep perft) · `zig build bench` · `-Doptimize=Debug` · `-Dtunables` (SPSA knobs,
never shipped) · `./zig-out/bin/koji uci|bench|perft <depth>|epd <file>` · `make EXE=Engine-X`.

## Zig 0.16: never write an unfamiliar API from memory
Training data is mostly Zig 0.13/0.14 and **will not compile**. Both sources ship inside the toolchain, so
ask the install where they are instead of hardcoding a path (`zig env` emits ZON in 0.16, not JSON), and
**grep, don't read** — both are large.
`STD=$(zig env | sed -n 's/^ *\.std_dir = "\(.*\)",$/\1/p')`
Signatures: `grep -rn "pub fn <name>" "$STD/"` · language and optimisation: `grep -n <x> "$STD/../../doc/langref.html"`
Breaks verified against a 0.16.0 install, so the common cases need no lookup: `@Type` is gone →
`@Int`/`@Struct`/`@Pointer`/`@Tuple` · all I/O goes through `std.Io` (`var fw: Io.File.Writer =
.init(.stdout(), io, &buf);` then `&fw.interface`, and **flush**) · entry point is `pub fn main(init:
std.process.Init) !void` · `addExecutable`/`addTest` require `root_module` · `trimLeft`/`trimRight` →
`std.mem.trimStart`/`trimEnd` · `ArrayList` is unmanaged (`.empty`, allocator passed to every method) ·
`ThreadSafeAllocator` is gone · vector indices must be comptime-known (assign to `[N]T` to index at
runtime) · no pointers in packed structs.

## Performance surface — reach for these
`@Vector` + `std.simd` (NNUE inference) · `@popCount`/`@ctz`/`@clz`/`@byteSwap` (bitboards) ·
labeled-switch `continue` for branch-predictor-friendly state machines (UCI parsing, movegen staging) ·
`@prefetch` (TT probes) · `inline for` · packed structs · explicit `align` for cache lines · comptime
table generation (Zobrist, magics, PSQT).
**`@branchHint(.likely)` on a branch that isn't actually likely is slower than no hint at all** — hint only
where profiling showed the skew. Same rule for the target: PEXT is fast on Zen 3+ and Haswell+ and slow on
older AMD, so detect it and keep both PEXT and plain magics rather than compiling the assumption in.

## Invariants
- `bench` is deterministic across runs **and machines** — identical node counts on AVX2 and non-AVX2
  builds. Keep every eval path integer; float accumulation reorders with SIMD width.
- Every commit touching search or eval carries `Bench: <nodes>` in its message.
- An illegal PV move is never cosmetic. It is a TT-collision bug — fix it immediately.
- A release build advertises only real UCI options. `Hash` and `Threads` are mandatory.

## Architecture
- `src/main.zig` — CLI dispatch and the UCI loop. Output *shapes* are contracts: OpenBench parses `<nodes> nodes <nps> nps`; GUIs parse the `uci` block.
- `build.zig` pins Zig 0.16.0 at comptime and gives every module an explicit `optimize` — a null one silently inherits, which is how you get an unexplained 3x in a bench.
- Phase 1 splits out `board.zig`, `move.zig`, `movegen.zig`, `perft.zig`; then `search.zig`,
  `eval.zig`, `tt.zig`, `nnue.zig`. Imports stay acyclic in that order — make/unmake lives in
  `move.zig` as a function over `*Board`, not as a `Board` method, for exactly that reason.
- Tests sit beside the code they test and **only run if reachable from `main.zig`'s import graph** — a file nothing imports is silently untested.
- Once those exist: the accumulator stack unwinds exactly with make/unmake; the TT never returns a move illegal in the current position.
- When this block outgrows ~15 lines, split it into `docs/architecture.md` and leave a pointer.

## Workflow
Start with `/next`. Branch `feat/<short>` off `main`; one Elo-affecting idea per branch; write the perft
or invariant test **first**; measure with `/bench` (speed) or `/sprt` (strength); record the outcome in
`docs/testlog.md` **either way — failures are the point**, since deleted branches leave no trace.
On green build + green tests + SPRT pass or proven bench-neutrality, push and open the PR, then stop:
**the human is the final gate and does the squash-merge — Claude never merges.** Squash keeps every
commit on `main` one validated idea carrying its own `Bench:` line — that is what keeps `git bisect`
usable when strength regresses. The PR title becomes the squash subject, so commit subjects and PR
titles share one style: `<type>: <what>`, lowercase type from `feat/fix/perf/docs/ci/test/chore`.
`main` is always green and always the strongest version.
**Never run two measurements at once**: an SPRT owns the whole machine and a concurrent run invalidates
*both*. Serialise anything that measures; parallel worktrees are for correctness and docs work only.

## Code review
`/code-review` on the branch before merging — only for changes to the TT, threading/atomics,
make/unmake, or the NNUE accumulator. Everywhere else SPRT is the authority.
`/code-review max <paths>` once per phase, over the merged and tagged subsystem, plus `/audit` for
the docs and `.claude/` setup. Why a decision was made lives in a comment where it is enforced —
read it before removing a rule that looks like an obstacle.

## Delegation
This session does all design and implementation. Chess research → `technique-researcher`; broad code search →
`Explore`; long SPRT and deep perft → **background Bash**, not subagents. Never delegate what to build.

## Four hard rules
1. **Never open another engine's source code.** Research from descriptions only — CPW, papers, PR and
   issue *discussion* (the thread, not the diff). `bullet`, `fastchess`, OpenBench and the UCI spec are
   shared tools, not engines, and are read normally. If a technique genuinely cannot be built from
   available descriptions, **stop and ask the human** — never fetch the source instead.
2. **Never reference an AGPL or unlicensed engine** in any form. Check the licence with
   `gh api repos/<owner>/<repo> --jq .license.spdx_id` before proposing a reference — never from memory.
3. **Write to the project, never to a person.** Commits, PRs and our own issues are fine. Comments,
   reviews, replies, TalkChess/Discord/Lichess messages are not — draft them for the human to send.
   **Never assess a plagiarism or licensing complaint about your own output**; surface it unanswered.
   Keep attribution claims — including "generated with" tool footers — out of commit messages and
   PR bodies; they belong in CREDITS.md, which already states how this engine is built.
4. Every technique gets `// origin: <who> via <url>` at the implementation site plus a CREDITS.md entry.
   `origin: unclear` is a valid answer — a confident wrong attribution is worse than none.
