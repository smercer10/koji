# Credits

koji is written by a human and Claude Code working together. It is not a port, a translation, or a
cleanup of another engine: no other engine's source is read during development. [Clean
room](#clean-room) below covers how that is held, and where the claim stops.

What it takes from the community is *ideas*, which are published and belong to the people who worked
them out. This file names them.

## Entry schema

Each technique gets one line at its implementation site:

```zig
// origin: <who, where> via <url>
```

and one entry here:

> **technique** — origin: *who, where* via *primary-source URL* — trail: *who shipped it, when*

Two rules:

1. **Attribution names the originator of the idea, not the best-known engine that shipped it.**
   Crediting "engine X's tables" for something engine X got from someone else launders the actual
   authorship.
2. **`origin: unclear (common to N+ engines)` is a valid and preferred answer.** Much of chess
   programming is folklore with no single inventor, and a confident wrong attribution is a bigger
   error than an honest blank.

## Techniques

> **bitboards** — origin: *Georgy Adelson-Velsky et al., 1967 (Kaissa); bitset methods in checkers
> earlier (Strachey 1952, Samuel mid-1950s)* via https://www.chessprogramming.org/Bitboards —
> trail: *Kaissa and Chess (Northwestern), late 1960s–70s*

> **bitboard+mailbox hybrid** — origin: *unclear (folklore; CPW documents the redundant-mailbox
> trade-off as common practice)* via https://www.chessprogramming.org/Board_Representation

## Clean room

Agents do not open other engines' source code. Research is from descriptions: the Chess Programming
Wiki, papers, release notes, and PR or issue discussion threads — the conversation, not the diff.

This is stricter than the human norm — engine authors read each other's code and say so. The
difference is that a model reproduces expression far more literally than a person reimplementing
from memory, so the question is closed by never opening the source. The strength cost is small: the
techniques are published, and what exists only in source is mostly constants tuned against another
engine's search tree, which would need retuning here regardless.

Two carve-outs. Shared community tools — `bullet`, `fastchess`, OpenBench, the UCI specification —
are read and used normally. Discussion threads are primary sources and are used for both concept and
attribution.

When a technique cannot be implemented from available descriptions, the rule is to stop and ask a
human, not to fetch the source instead.

This is enforced by the tooling rather than asserted:
[`.claude/hooks/guard.sh`](.claude/hooks/guard.sh) blocks fetches that resolve to source — raw file
and archive hosts, GitHub's code browser, commit pages, and a pull request's diff in any form —
while leaving the discussion on that same pull request reachable
(`.claude/hooks/guard_test.sh` holds the vectors). The researcher agent
([`.claude/agents/technique-researcher.md`](.claude/agents/technique-researcher.md)) and the allowlist in
[`.claude/settings.json`](.claude/settings.json) narrow it further.

All of that constrains what the agent reads. It cannot constrain what a model already knows —
Claude's training data is not auditable and contains engine source. So this is a claim about
process, which is the strongest one available here, and not a guarantee about every line.

CPW content is CC BY-SA 3.0, so it is linked and paraphrased, never pasted into this repository.

## Licences

koji is GPL-3.0. AGPL-3.0 code cannot be relicensed as GPL-3.0, so AGPL-licensed and unlicensed
engines are not referenced here in any form.

The licence of a project is checked when it is added to this file, not recalled:

```
gh api repos/<owner>/<repo> --jq .license.spdx_id
```

Projects relicense, so a remembered licence is a guess. There is no pre-approved or pre-excluded
list here — the check is one command and belongs at the moment of use.

## Naming

Takedown requests — naming, attribution, testing opponents — are handled per the note at the end
of [README.md](README.md): open an issue.
