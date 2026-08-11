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

*Nothing yet — Phase 0 is scaffolding only. Entries land as techniques do.*

## Clean room

Agents do not open other engines' source code. Research is from descriptions: the Chess Programming
Wiki, papers, release notes, and PR or issue discussion threads — the conversation, not the diff.

Two carve-outs. Shared community tools — `bullet`, `fastchess`, OpenBench, the UCI specification —
are read and used normally. Discussion threads are primary sources and are used for both concept and
attribution.

When a technique cannot be implemented from available descriptions, the rule is to stop and ask a
human, not to fetch the source instead.

This is enforced by the tooling rather than asserted:
[`.claude/hooks/guard.sh`](.claude/hooks/guard.sh) blocks fetches that resolve to source — raw file
hosts, GitHub's `/blob/` and `/raw/` views, and a pull request's diff tab — while leaving the
discussion on that same pull request reachable. The researcher agent
([`.claude/agents/cpw-researcher.md`](.claude/agents/cpw-researcher.md)) and the allowlist in
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

If you recognise your code here, or you would rather your engine were not named in this repository
or used as a testing opponent, open an issue — it gets fixed or removed. No case to argue.
