# Decisions

Rules whose cost is obvious and whose reason is not.

A decision with a code site gets a comment there instead — that is where someone will be standing
when they question it. This file is only for the few that have nowhere else to live. If an entry is
already covered by a comment or by CLAUDE.md, delete it from here.

---

**Agents never read another engine's source.** This is stricter than the norm: human engine authors
read each other's code routinely and say so. The reason is that the question about an LLM-written
engine is proximity of *expression*, and a model reproduces expression far more literally than a
person reimplementing from memory. If the source is never opened, that question is closed
structurally rather than argued.

The part worth writing down is that the strength cost is near zero, because the rule will look
expensive every time it is inconvenient. Strength comes from correct implementations of published
ideas, plus your own tuned parameters and your own training data. Reading source gets you neither:
the techniques are described in papers and on CPW, and what exists only in source is the precise
reduction formulas and constants — which do not transfer, because they are tuned against another
engine's search tree. You have to tune your own regardless. The rule costs convenience, not ceiling.

**Permissions stop at addressing a person, not at touching GitHub.** Commits, PRs and our own issues
are unrestricted; comments, reviews and replies on other people's work are blocked. Drawing the line
at "touching GitHub" would have been simpler and would have made ordinary work painful — and a
control that obstructs ordinary work gets switched off, after which it protects nothing.
