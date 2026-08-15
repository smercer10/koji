#!/usr/bin/env bash
# Stop hook: refuse to end the turn having padded the prose.
#
# CLAUDE.md, docs/testlog.md and ROADMAP.md already carry these rules. This file
# does not restate them, it checks them — the same split guard.sh has from the
# engine-source rule. Every budget is measured off `main` and the derivation is
# quoted at each check, so it can be re-derived rather than guessed at.
#
# There is no override flag on purpose, but there are two right answers to a
# block, not one. Cut, *or* — if the prose is genuinely already minimal — say so
# to the human and let them decide. Trimming a load-bearing comment because a
# ratio said to is the same defect in the other direction, and this file would
# rather be argued with than obeyed into deleting something that was holding a
# rule up.
#
# That second path already works: Claude Code re-runs Stop hooks after a block
# and the `stop_hook_active` guard below passes on the second run, so a turn that
# states its case can still end. Stating it is the price, and that is the point —
# the human sees the disagreement instead of the budget quietly winning.
set -uo pipefail

input="$(cat)"

# Claude Code re-runs Stop hooks after a block; without this a disagreement with
# the budget would loop forever. Same guard gate.sh uses.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]]; then
  exit 0
fi

root="${CLAUDE_PROJECT_DIR:-.}"
if ! cd "$root" 2>/dev/null || ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "prose.sh: '$root' is not a git checkout, so the prose budget did not run." >&2
  exit 2
fi

# Nothing to police on a branch that has not diverged.
base="$(git merge-base HEAD main 2>/dev/null || echo '')"
[[ -z "$base" ]] && exit 0

fail=0
say() { printf '%s\n' "$*" >&2; fail=1; }

# --- docs/testlog.md ----------------------------------------------------------
#
# One entry per change — `feat/tt` folded its SPRT into its bench entry. A reader
# looking up a branch should find one place, not two to reconcile.
if [[ -f docs/testlog.md ]]; then
  dupe="$(grep -oE '^- branch:[[:space:]]+\S+' docs/testlog.md | awk '{print $3}' \
          | sort | uniq -d)"
  if [[ -n "$dupe" ]]; then
    say "testlog: more than one entry for the same branch — fold them into one:"
    say "$(sed 's/^/  /' <<<"$dupe")"
  fi

  # Entries on main ran 7-53 lines; 60 leaves headroom over the largest.
  over="$(awk '
    /^### /   { if (name != "" && n > 60) printf "  %s (%d lines)\n", name, n
                name = substr($0, 5); n = 0 }
    name != "" { n++ }
    END       { if (name != "" && n > 60) printf "  %s (%d lines)\n", name, n }
  ' docs/testlog.md)"
  if [[ -n "$over" ]]; then
    say "testlog: entry over the 60-line budget (existing entries run 7-53):"
    say "$over"
    say "  Keep what only the measurement can tell you — what the code does, what"
    say "  bugs turned up and why a design was chosen are in git log and at the"
    say "  implementation site. If it is already only numbers, say so and ask."
  fi
fi

# --- ROADMAP.md ---------------------------------------------------------------
#
# 34 of the 42 items on main are one line and the longest is five, which is the
# budget: a check that scolds about content already on main gets ignored.
if [[ -f ROADMAP.md ]]; then
  long="$(awk '
    /^- \[[ x]\]/ { if (n > 5) printf "  %s (%d lines)\n", substr(item, 1, 60), n
                    item = $0; n = 1; next }
    /^      /     { if (item != "") n++; next }
                  { if (item != "" && n > 5) printf "  %s (%d lines)\n", substr(item, 1, 60), n
                    item = ""; n = 0 }
    END           { if (item != "" && n > 5) printf "  %s (%d lines)\n", substr(item, 1, 60), n }
  ' ROADMAP.md)"
  if [[ -n "$long" ]]; then
    say "ROADMAP: item over 5 lines — say it in one, or make the case for the rest:"
    say "$long"
  fi
fi

# --- comment density ----------------------------------------------------------
#
# Not a cap: koji is deliberately comment-heavy, and files on main sit between
# 0.27 and 0.62. This catches *ratcheting* — a file may hold or lower its
# density, and +0.05 is the tolerance for genuinely new surface.
ratio() { # ratio <blob-or-path> ; prints hundredths, integer
  local c t
  c="$(grep -cE '^[[:space:]]*//' <<<"$1" || true)"
  t="$(grep -cE '^[[:space:]]*[^/[:space:]]' <<<"$1" || true)"
  (( t == 0 )) && { echo 0; return; }
  echo $(( c * 100 / t ))
}

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  now="$(ratio "$(cat "$f")")"
  was="$(ratio "$(git show "$base:$f" 2>/dev/null || true)")"
  # A file that did not exist on the base has no density to ratchet against;
  # judge it against the densest file on main rather than exempting it.
  (( was == 0 )) && was=62
  if (( now > was + 5 )); then
    say "comments: $f is at 0.$(printf '%02d' "$now") comments/code, was 0.$(printf '%02d' "$was")."
    say "  A comment earns its place by stopping someone breaking the rule it"
    say "  guards, not by recording what happened. **If you have already cut to"
    say "  that and the density still says no, stop and put the case to the"
    say "  human** — name the comments and what each one prevents. Do not keep"
    say "  cutting past the point where the file stops explaining itself."
  fi
done < <({ git diff --name-only "$base"...HEAD -- 'src/*.zig'
           git diff --name-only -- 'src/*.zig'; } | sort -u)

(( fail )) && exit 2
exit 0
