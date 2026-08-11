# koji

A UCI chess engine written in Zig 0.16, with no external dependencies. Built by a human and Claude
Code working together.

Current state: **Phase 0 complete.** The build, test and benchmark spine works and the UCI handshake
is well-formed. The engine cannot play yet: board representation and move generation are Phase 1.
See [ROADMAP.md](ROADMAP.md).

## What this is

An experiment in agentic development, run against a problem that scores itself: how far the method
can go, and whether it discovers anything on the way. Chess engines suit that job — strength is
settled in Elo rather than argument, and there are thirty years of published technique to build
from. The test log records every idea tried and its result, including the failures.

It is a collaboration over many sessions, not a single prompt. Claude Code writes nearly all of the
code; the human sets the direction, decides what is worth trying, reviews what comes back, and owns
what lands on `main`.

The code is written from published descriptions rather than from other engines' source. Zig helps
hold that line: there is very little existing Zig engine code to reproduce, and idiomatic Zig does
not map line by line from other languages regardless.

## Build

Requires Zig 0.16.0 exactly — `build.zig` enforces this at comptime.

```
zig build                  # ReleaseFast by default
./zig-out/bin/koji uci
```

| Command | Purpose |
|---|---|
| `zig build test` | unit tests + shallow perft |
| `zig build test-slow` | deep perft |
| `zig build bench` | fixed benchmark; prints `<nodes> nodes <nps> nps` |
| `make EXE=Engine-XYZ` | OpenBench-compatible build |

The engine binary is also the tooling: `koji bench`, `koji perft <depth>` and `koji epd <file>`
are subcommands rather than scripts, so they cannot drift out of sync with the engine they measure.

## How it works

Nothing is implemented yet, so there is nothing honest to describe here. This section gets filled in
as the engine acquires a board representation, a search, and an evaluation — not before.

## How this project is built

koji is developed with Claude Code under human direction — nothing reaches `main` without a human
reviewing and merging it. The setup that makes that repeatable lives in the repository:

- Agent instructions, permissions, hooks and skills: [`.claude/`](.claude/) and
  [`CLAUDE.md`](CLAUDE.md)
- Phases and their exit criteria: [ROADMAP.md](ROADMAP.md)
- Every strength test run, including the ones that failed: [`docs/testlog.md`](docs/testlog.md)
- Techniques and their origins: [CREDITS.md](CREDITS.md)

Agents work from published descriptions — the Chess Programming Wiki, papers, and PR or issue
discussion — and not from other engines' source code. A hook
([`.claude/hooks/guard.sh`](.claude/hooks/guard.sh)) blocks fetches that resolve to source, including
a pull request's diff while leaving its discussion reachable; the researcher agent
([`.claude/agents/cpw-researcher.md`](.claude/agents/cpw-researcher.md)) and the allowlist in
[`.claude/settings.json`](.claude/settings.json) narrow it further. That constrains what the agent
reads, not what a model already knows from training — the honest limit of the claim, and the
reasoning is in [CREDITS.md](CREDITS.md).

From Phase 3 onward, every merge affecting playing strength is gated on an SPRT result, recorded in
`docs/testlog.md` whether it passed or failed.

If you recognise your code here, or you would rather koji did not name your engine or use it as a
testing opponent, open an issue — it gets fixed or removed. No case to argue.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
