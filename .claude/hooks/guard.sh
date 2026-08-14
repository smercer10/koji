#!/usr/bin/env bash
# PreToolUse hook: enforce the rules that permission patterns cannot express.
#
# Rules match a Bash command by prefix and a WebFetch URL by hostname only, and
# Claude Code recognises the ":*" wildcard only at the end of a pattern. None of
# "gh aimed at another repository", "a GitHub URL that is source rather than
# discussion", or "a merge" can be written as a rule. All are claims this repo
# makes in public, so they are enforced here instead of asserted.
#
# The line is drawn at addressing a person and at merging, not at touching
# GitHub: commits, PRs and this repo's own issues stay open, because a control
# that obstructs ordinary work ends up switched off. That cuts both ways — a
# *wrong* block teaches the same lesson, which is why the gh rules below read
# one command at a time rather than scanning the whole line.
#
# Exiting 2 stops the call before permission rules are evaluated.
set -uo pipefail

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"

block() {
  printf '%s\n' "$@" >&2
  exit 2
}

self="$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2>/dev/null |
  sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"

# Is this owner/name somewhere other than the repository we are working in?
# With no remote configured, anything explicitly named is by definition elsewhere.
elsewhere() {
  [[ -z "$self" || "${1,,}" != "${self,,}" ]]
}

# Source, not description: the code browser, raw file bodies, whole-tree
# archives, and a diff in any wrapper. The discussion on a PR is fine and is what
# research is supposed to use; repository roots are left alone so cloning a
# shared tool still works.
#
# Path segments are matched with no host qualifier on purpose -- GitLab spells
# its browser /-/blob/ and Gitea /src/branch/, but each contains a segment named
# here, so one rule covers the forges instead of one rule per forge, which is a
# list that is always one forge out of date. Lowercased because hostnames are
# case-insensitive. The extension list is a backstop for hosts not named here and
# must never be the only rule covering one: guard_test.sh carries an
# extensionless vector for each, and mutation-tests that they are load-bearing.
looks_like_source() {
  local u="${1,,}"
  [[ "$u" =~ (raw|patch-diff)\.githubusercontent\.com ]] ||
    [[ "$u" =~ codeload\.github\.com ]] ||
    [[ "$u" =~ /(blob|raw|commit|commits|blame|tree)/ ]] ||
    [[ "$u" =~ /src/(branch|commit|tag)/ ]] ||
    [[ "$u" =~ /(archive|tarball|zipball)/ ]] ||
    [[ "$u" =~ /pull/[^/]+/(files|commits) ]] ||
    [[ "$u" =~ \.(zip|tar\.gz|tgz|7z|xz)(\?|#|$) ]] ||
    [[ "$u" =~ \.(c|cc|cpp|cxx|h|hh|hpp|inl|rs|zig|go|java|py|s|asm|diff|patch)(\?|#|$) ]]
}

# gh api endpoints that return file bodies or a whole tree. These are the reads
# the cross-repo carve-out below must not cover: `gh api repos/<o>/<r>/contents/
# src/search.cpp` returns the file just as surely as fetching the blob page.
returns_source() {
  [[ "$1" =~ /(contents|tarball|zipball)(/|$|\?) ]] ||
    [[ "$1" =~ /git/(blobs|trees)(/|$|\?) ]]
}

# Rule 3 is about addressing a person, and the REST spelling of a comment is not
# a `gh pr comment` prefix any permission rule can match.
addresses_a_person() {
  [[ "$1" =~ /(comments|reviews)(/|$|\?) ]]
}

case "$tool" in
Bash)
  cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
  [[ -z "$cmd" ]] && exit 0

  # curl and wget reach the same URLs WebFetch does. The scheme is optional
  # because curl treats a bare host as http:// and GitHub redirects, so requiring
  # it skipped the check entirely. The host must still look like a host, which
  # keeps paths like .claude/hooks/guard.sh from being read as URLs.
  while read -r url; do
    [[ -z "$url" ]] && continue
    looks_like_source "$url" &&
      block "Blocked: $url looks like source code, not a description." \
        "Research from the discussion, the paper, or the CPW page."
  done < <(grep -oE '(https?://)?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}/[^ "'\''<>]+' <<<"$cmd")

  # A command line is a sequence of commands, so the rules below see one command
  # at a time. Scanning the whole string blocked `gh --version; grep -R src/main
  # .` as "gh targeting src/main", and its substring test fired on any word
  # containing "gh".
  while IFS= read -r segment; do
    seg="${segment#"${segment%%[![:space:]]*}"}"
    [[ -z "$seg" ]] && continue

    # Leading VAR=value assignments belong to the command that follows. GH_REPO
    # names a repository without --repo, and by moving the command's first word
    # it also slips past every permission rule keyed on "gh ...".
    env_repo=""
    while [[ "$seg" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)[[:space:]]+(.*)$ ]]; do
      [[ "${BASH_REMATCH[1]}" == "GH_REPO" ]] && env_repo="${BASH_REMATCH[2]//[\"\']/}"
      seg="${BASH_REMATCH[3]}"
    done

    case "${seg%%[[:space:]]*}" in
    git)
      # The human is the final gate and does the squash-merge.
      [[ "$seg" =~ ^git[[:space:]]+merge([[:space:]]|$) ]] &&
        block "Blocked: merging is the human's call, not an agent's." \
          "Open the PR and stop there; CLAUDE.md's Workflow is explicit about this."
      if [[ "$seg" =~ ^git[[:space:]]+push([[:space:]]|$) ]]; then
        [[ "$seg" =~ [[:space:]](main|master)([[:space:]]|:|$) ]] &&
          block "Blocked: pushing to main. Work lands there by squash-merge, by a human." \
            "Push the feature branch and open a PR instead."

        # The checkout's own branch decides only for the forms that push it: a
        # bare push, `git push <remote>`, or an explicit HEAD. Consulting it for
        # every push refused `git push -u origin <feature>` run from main, which
        # pushes the feature branch and not main -- and that wrong block reached
        # main, because these vectors had only ever run from a feature branch.
        refspecs="$(sed -E 's/^git[[:space:]]+push//' <<<"$seg" |
          tr -s '[:space:]' '\n' | grep -cE '^[^-]' || true)"
        if ((refspecs <= 1)) || [[ "$seg" =~ [[:space:]]HEAD([[:space:]]|:|$) ]]; then
          branch="$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null)"
          [[ "$branch" == "main" || "$branch" == "master" ]] &&
            block "Blocked: that pushes main, which is where work lands by squash-merge, by a human." \
              "Push the feature branch and open a PR instead."
        fi
      fi
      ;;
    gh)
      [[ "$seg" =~ ^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]] &&
        block "Blocked: Claude never merges — the human is the final gate." \
          "The PR is open; stop there."

      # Every way this command can name a repository: --repo/-R (quoted or not),
      # GH_REPO, and the URL form, which gh accepts in place of a number and
      # which carries no --repo to find.
      targets="$(
        {
          grep -oE -- '(--repo|-R)[= ]+["'\'']?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' <<<"$seg" |
            sed -E 's/^(--repo|-R)[= ]+["'\'']?//'
          grep -oE 'github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' <<<"$seg" |
            sed -E 's#^github\.com/##'
          printf '%s\n' "$env_repo"
        } | sed '/^$/d' | sort -u
      )"
      while read -r target; do
        [[ -z "$target" ]] && continue
        elsewhere "$target" &&
          block "Blocked: gh targeting '$target', which is not this repository${self:+ ($self)}." \
            "Agents write to this project only. Draft it for a human to send instead."
      done <<<"$targets"

      if [[ "$seg" =~ ^gh[[:space:]]+api([[:space:]]|$) ]]; then
        path="$(grep -oE '(repos|orgs)/[^ "'\'']+' <<<"$seg" | head -1)"

        # Rule 3 holds on this repository too, so this one is not about who owns
        # the endpoint.
        addresses_a_person "$path" &&
          block "Blocked: that endpoint posts a comment or a review." \
            "Write to the project, never to a person. Draft it for a human to send."

        api_target="$(sed -E 's#^(repos|orgs)/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+).*#\2#' <<<"$path")"

        # Reads stay open -- rule 2's licence check is a cross-repo GET -- but
        # only those returning facts about a repository. Gating on a write flag
        # instead let every file-body endpoint through: it blocked `gh search
        # code --repo` while permitting the `contents/` call itself.
        if returns_source "$path" && elsewhere "$api_target"; then
          block "Blocked: that endpoint returns another repository's source." \
            "Research from descriptions only. If a technique genuinely cannot be" \
            "built from them, stop and ask the human."
        fi

        # A write must name this repository. No repos/ path at all also blocks:
        # that is where graphql mutations land.
        if [[ "$seg" =~ [[:space:]](-X|-f|-F|--method|--field|--raw-field|--input)([=[:space:]]|$) ]]; then
          [[ -z "$path" ]] &&
            block "Blocked: gh api write with no repos/<owner>/<repo> in its path." \
              "Agents write to this project only. Draft it for a human to send instead."
          elsewhere "$api_target" &&
            block "Blocked: gh api write targeting '$api_target', which is not this repository${self:+ ($self)}." \
              "Agents write to this project only. Draft it for a human to send instead."
        fi
      fi
      ;;
    esac
  done < <(sed -E 's/\|\||&&/\n/g; s/[;|&]/\n/g' <<<"$cmd")
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
