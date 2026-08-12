#!/usr/bin/env bash
# PreToolUse hook: enforce the two rules that permission patterns cannot express.
#
# Rules match a Bash command by prefix and a WebFetch URL by hostname only, and
# Claude Code recognises the ":*" wildcard only at the end of a pattern. Neither
# "gh aimed at another repository" nor "a GitHub URL that is source rather than
# discussion" can be written as a rule. Both are claims this repo makes in
# public, so they are enforced here instead of asserted.
#
# The line is drawn at addressing a person, not at touching GitHub: commits,
# PRs and this repo's own issues stay open, because a control that obstructs
# ordinary work ends up switched off.
#
# Exiting 2 stops the call before permission rules are evaluated.
set -uo pipefail

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"

block() {
  printf '%s\n' "$@" >&2
  exit 2
}

# Source, not description. /blob/ and /raw/ are the code browser; a commit page
# and a PR's /files or /commits tab are the diff; .diff/.patch URLs and the raw
# and archive hosts are source in a different wrapper. The discussion on the
# same PR is fine and is exactly what research is supposed to use. Repository
# roots are left alone so that cloning a shared tool -- bullet, fastchess --
# still works.
looks_like_source() {
  [[ "$1" =~ (raw|patch-diff)\.githubusercontent\.com ]] ||
    [[ "$1" =~ codeload\.github\.com ]] ||
    [[ "$1" =~ github\.com/[^/]+/[^/]+/(blob|raw|commit)/ ]] ||
    [[ "$1" =~ github\.com/[^/]+/[^/]+/pull/[^/]+/(files|commits) ]] ||
    [[ "$1" =~ \.(c|cc|cpp|cxx|h|hpp|rs|zig|go|java|py|diff|patch)(\?|#|$) ]]
}

case "$tool" in
Bash)
  cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
  [[ -z "$cmd" ]] && exit 0

  # curl and wget reach the same URLs WebFetch does. Extract URLs wherever they
  # appear -- word-splitting missed quoted URLs, which is how they are usually
  # written.
  while read -r url; do
    [[ -z "$url" ]] && continue
    looks_like_source "$url" &&
      block "Blocked: $url looks like source code, not a description." \
        "Research from the discussion, the paper, or the CPW page."
  done < <(grep -oE 'https?://[^ "'\''<>]+' <<<"$cmd")

  [[ "$cmd" != *gh* ]] && exit 0

  # The repository this checkout actually is. Empty before a remote exists, in
  # which case any explicit --repo is by definition somewhere else.
  self="$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2>/dev/null |
    sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"

  while read -r target; do
    [[ -z "$target" ]] && continue
    if [[ -z "$self" || "$target" != "$self" ]]; then
      block "Blocked: gh targeting '$target', which is not this repository${self:+ ($self)}." \
        "Agents write to this project only. Draft it for a human to send instead."
    fi
  done < <(grep -oE -- '(--repo|-R)[= ]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' <<<"$cmd" |
    sed -E 's/^(--repo|-R)[= ]+//')

  # gh api names the repository in the endpoint path, not --repo. Reads stay
  # open -- the licence check in CLAUDE.md rule 2 is a cross-repo GET -- but a
  # call carrying a write indicator must name this repository in its path. No
  # repos/ path at all also blocks: that is where graphql mutations land.
  if [[ "$cmd" =~ gh[[:space:]]+api ]] &&
    [[ "$cmd" =~ [[:space:]](-X|-f|-F|--method|--field|--raw-field|--input)([=[:space:]]|$) ]]; then
    targets="$(grep -oE 'repos/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' <<<"$cmd" |
      sed 's#^repos/##' | sort -u)"
    [[ -z "$targets" ]] &&
      block "Blocked: gh api write with no repos/<owner>/<repo> in its path." \
        "Agents write to this project only. Draft it for a human to send instead."
    while read -r target; do
      if [[ -z "$self" || "$target" != "$self" ]]; then
        block "Blocked: gh api write targeting '$target', which is not this repository${self:+ ($self)}." \
          "Agents write to this project only. Draft it for a human to send instead."
      fi
    done <<<"$targets"
  fi
  ;;

WebFetch)
  url="$(jq -r '.tool_input.url // empty' <<<"$input")"
  [[ -z "$url" ]] && exit 0

  if looks_like_source "$url"; then
    block "Blocked: $url looks like source code, not a description." \
      "Research from the discussion, the paper, or the CPW page. If a technique" \
      "genuinely cannot be built from descriptions, stop and ask the human."
  fi
  ;;
esac

exit 0
