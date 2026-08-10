# koji

A UCI chess engine written in Zig 0.16, with no external dependencies.

Current state: **Phase 0 — scaffolding.** The build, test and benchmark spine works and the UCI
handshake is well-formed; there is no move generation or search yet. See [ROADMAP.md](ROADMAP.md).

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

koji is developed with Claude Code. The development setup lives in the repository:

- Agent instructions, permissions, hooks and skills: [`.claude/`](.claude/) and
  [`CLAUDE.md`](CLAUDE.md)
- Phases and their exit criteria: [ROADMAP.md](ROADMAP.md)
- Every strength test run, including the ones that failed: [`docs/testlog.md`](docs/testlog.md)
- Techniques and their origins: [CREDITS.md](CREDITS.md)

Agents work from published descriptions — the Chess Programming Wiki, papers, and PR or issue
discussion — and not from other engines' source code. This is enforced by
[`.claude/agents/cpw-researcher.md`](.claude/agents/cpw-researcher.md) and the fetch allowlist in
[`.claude/settings.json`](.claude/settings.json).

From Phase 3 onward, every merge affecting playing strength is gated on an SPRT result, recorded in
`docs/testlog.md` whether it passed or failed.

If you are an engine author and would rather your engine were not named here, or not used as a
testing opponent, open an issue and it will be removed.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
