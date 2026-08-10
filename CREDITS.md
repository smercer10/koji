# Credits

koji is original code. It is not a port, a translation, or a cleanup of another engine, and no
other engine's source was read while writing it — see "Clean room" below.

What koji does take from the community is *ideas*, which are published, discussed openly, and
belong to the people who worked them out. This file is where they are named.

## Entry schema

Each technique gets one line at its implementation site:

```zig
// origin: <who, where> via <url>
```

and one entry here:

> **technique** — origin: *who, where* via *primary-source URL* — trail: *who shipped it, when*

Two rules make this honest rather than decorative:

1. **Attribution names the originator of the idea, not the best-known engine that shipped it.**
   Crediting "engine X's tables" for something engine X got from someone else is worse than saying
   nothing, because it launders the actual authorship.
2. **`origin: unclear (common to N+ engines)` is a valid and preferred answer.** Much of chess
   programming is genuinely folklore with no single inventor. A confident wrong attribution is a
   bigger error than an honest blank.

## Techniques

*Nothing yet — Phase 0 is scaffolding only. Entries land as techniques do.*

## Clean room

Agents working on this repo **never open another engine's source code.** Research is from
descriptions: the Chess Programming Wiki, papers, release notes, and PR/issue *discussion threads*
(the conversation, not the diff). This is stricter than the norm among human engine authors, who
routinely read each other's code and say so. It is deliberate: the whole question about an
LLM-written engine is proximity of *expression*, and a model reproduces expression far more
literally than a person reimplementing from memory. If the source is never opened, the question is
structurally closed rather than merely denied.

The enforcement is in the tooling, not in good intentions — see `.claude/agents/cpw-researcher.md`
and the `WebFetch` allowlist in `.claude/settings.json`.

Two carve-outs, so the rule doesn't block the standard toolchain:

- **Shared tools are not engines.** `bullet`, `fastchess`, OpenBench and the UCI specification are
  shared infrastructure and are read and used normally.
- **Discussion threads are primary sources** and may be read for concept and attribution.

If a technique genuinely cannot be implemented from available descriptions, the rule is to **stop
and ask a human**, never to fetch the source instead. Each time that happens it is a signal the
technique is under-documented — which makes writing it up a real contribution.

## Licence exclusion list

koji is GPL-3.0. **AGPL-3.0 code cannot be relicensed as GPL-3.0**, so AGPL and unlicensed
engines are never referenced here in any form — not as a source, not as an attribution target, and
not as a description to work from. This gate is applied *before* research begins, not as a later
audit.

Licences below were checked via the GitHub API on **2026-08-10**, not from memory, and are
re-checked before any new reference is added. Projects do relicense; a remembered licence is a
guess.

| Project | Licence | Status here |
|---|---|---|
| Monty | AGPL-3.0 | **Excluded** |
| Reckless | AGPL-3.0 | **Excluded** |
| Icarus | AGPL-3.0 | **Excluded** |
| Stockfish | GPL-3.0 | Referenceable (descriptions only) |
| Berserk | GPL-3.0 | Referenceable (descriptions only) |
| PlentyChess | GPL-3.0 | Referenceable (descriptions only) |
| Stormphrax | GPL-3.0 | Referenceable (descriptions only) |
| Ethereal | GPL-3.0 | Referenceable (descriptions only) |
| bullet | MIT | Shared tool — used directly |
| fastchess | MIT | Shared tool — used directly |

"Referenceable" means *its published descriptions may be read and its authors credited*. It does
not mean its source may be opened. Nothing in this repo permits that.

## A standing invitation

If you are an engine author and you would rather your engine were not named in this repository, or
not used as a testing opponent, open an issue and it will be done — immediately, with no
negotiation and no case to argue.

There is deliberately no opt-out register here. An empty list would be performative, and a register
would institutionalise a conflict it cannot actually settle: if an engine genuinely is a technique's
origin and its author asks not to be named, deleting the credit makes the attribution *worse*. The
only thing that resolves that is asking the person which they prefer. Hence an invitation rather
than a form. Nobody should have to escalate to get their name removed.
