---
name: audit
description: Check the docs and .claude setup for drift — stale claims, dead references, duplicated rules, bloat, and configuration that no longer matches how Claude Code works. Run at phase boundaries.
---

# Audit the docs and setup

`/code-review` covers the code. Nothing covers the docs or `.claude/`, and both rot in ways that stay
invisible until they mislead a session: a path that moved, a rule stated in two places that have
since disagreed, a paragraph nobody reads.

**Run at each phase boundary**, alongside the phase's `/code-review max`. Also run it after a
material change to Claude Code itself, since this setup was built against a moving target.

## Checks

1. **Truth.** Execute every command quoted in the docs and skills; open every path and link they
   name. A source-of-truth rule pointing at a path that no longer resolves silently degrades every
   future session — the highest-value check here.
2. **Staleness.** `ROADMAP.md` checkboxes against what exists. Claims that stopped being true, and
   claims that became true and should now be added — the give-back link appears when there is
   something to link, not before.
3. **Gaps.** A rule being followed in practice but written down nowhere, or a decision made ad hoc
   that belongs in `docs/decisions.md`.
4. **Attribution.** Every `// origin:` comment in the code has a `CREDITS.md` entry, and every entry
   still points at code that exists.
5. **Duplication.** One rule, one home. A rule with a code site lives as a comment there; a second
   copy elsewhere will drift and then contradict it.
6. **Leanness.** Every doc, not just `CLAUDE.md`: could this say the same thing in fewer lines? Cut
   anything whose removal would not cause a mistake. If the architecture block has outgrown ~15
   lines, split it into `docs/architecture.md`.
7. **Voice.** Factual, describing what the project does. Flag anything claiming a virtue, assuming
   what a reader wants, arguing a case, or promising something not yet done.
8. **Setup currency.** Hooks fire — test the failure path, not just the pass. Skills load. Permissions
   match real traffic (`/fewer-permission-prompts`). Deny rules still block what they should. Check
   whether newer Claude Code features have made part of this setup redundant.

## Output

Concrete edits, most important first — not an essay, not a rewrite. Change only what is wrong, stale,
missing, duplicated, or bloated. Rewriting for style alone is churn and buries the real findings.
