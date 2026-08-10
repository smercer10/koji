#!/usr/bin/env bash
# PreToolUse hook: enforce the two rules that permission patterns cannot express.
#
# Rules match a Bash command by prefix and a WebFetch URL by hostname only, and
# Claude Code recognises the ":*" wildcard only at the end of a pattern. Neither
# "gh aimed at another repository" nor "a GitHub URL that is source rather than
# discussion" can be written as a rule. Both are claims this repo makes in
# public, so they are enforced here instead of asserted.
#
# Exiting 2 stops the call before permission rules are evaluated.
set -uo pipefail

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"

block() {
  printf '%s\n' "$@" >&2
  exit 2
}

# Source, not description. /blob/ and /raw/ are the code browser; a PR's /files
# tab is the diff. The discussion on the same PR is fine and is exactly what
# research is supposed to use. Repository roots are left alone so that cloning a
# shared tool -- bullet, fastchess -- still works.
looks_like_source() {
  [[ "$1" =~ raw\.githubusercontent\.com ]] ||
    [[ "$1" =~ github\.com/[^/]+/[^/]+/(blob|raw)/ ]] ||
    [[ "$1" =~ github\.com/.*/(pull|commit)/[^/]+/files ]] ||
    [[ "$1" =~ \.(c|cc|cpp|cxx|h|hpp|rs|zig|go|java|py)(\?|#|$) ]]
}

case "$tool" in
Bash)
  cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
  [[ -z "$cmd" ]] && exit 0

  # curl and wget reach the same URLs WebFetch does.
  for word in $cmd; do
    case "$word" in
    http://* | https://*)
      looks_like_source "$word" &&
        block "Blocked: $word looks like source code, not a description." \
          "Research from the discussion, the paper, or the CPW page."
      ;;
    esac
  done

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
