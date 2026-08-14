#!/usr/bin/env bash
# Failure-path test for guard.sh. Run after any edit to guard.sh, from CI, and
# from /audit at every phase boundary: bash .claude/hooks/guard_test.sh
#
# Vectors live in this file rather than in the invoking command because the live
# hook scans command text -- a probe typed into a session blocks itself. Engine
# names are placeholders; no real project is referenced and nothing is fetched.
#
# Two properties this suite is built for, both learned by finding it lacked them:
#
#   1. Every rule is covered *independently*. A vector ending in .cpp is caught
#      by the source-extension backstop no matter what the host rules say, so a
#      suite made of those reports "all vectors pass" against a guard with whole
#      rules deleted -- verified by mutation, and it did. Each host and path rule
#      below therefore gets a vector with no source extension on it.
#   2. The must-pass half is a test, not a courtesy. A guard that blocks ordinary
#      work gets switched off, which protects nothing.
set -uo pipefail
cd "$(dirname "$0")"
export CLAUDE_PROJECT_DIR="$(cd ../.. && pwd)"

self="$(git -C "$CLAUDE_PROJECT_DIR" remote get-url origin 2>/dev/null |
  sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"

fail=0
checked=0
check() { # <expected-exit> <description> <json>
  checked=$((checked + 1))
  printf '%s' "$3" | ./guard.sh >/dev/null 2>&1
  local got=$?
  if [[ "$got" != "$1" ]]; then
    fail=1
    echo "FAIL (exit $got, want $1): $2"
  fi
}
wf() { printf '{"tool_name":"WebFetch","tool_input":{"url":"%s"}}' "$1"; }
ba() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

GH='https://github.com/example/engine'

# --- must block: source in any wrapper ----------------------------------------
# Each of these carries a source extension, so each is covered twice over.
check 2 'blob view'            "$(wf "$GH/blob/master/src/search.cpp")"
check 2 'raw view'             "$(wf "$GH/raw/master/src/search.cpp")"
check 2 'raw host'             "$(wf 'https://raw.githubusercontent.com/example/engine/master/src/eval.h')"
check 2 'commit page (a diff)' "$(wf "$GH/commit/abc1234")"
check 2 'PR files tab'         "$(wf "$GH/pull/123/files")"
check 2 'PR commits tab'       "$(wf "$GH/pull/123/commits")"
check 2 'PR .diff'             "$(wf "$GH/pull/123.diff")"
check 2 'PR .patch'            "$(wf "$GH/pull/123.patch")"
check 2 'patch-diff host'      "$(wf 'https://patch-diff.githubusercontent.com/raw/example/engine/pull/123.patch')"
check 2 'codeload tarball'     "$(wf 'https://codeload.github.com/example/engine/tar.gz/master')"
check 2 'source extension'     "$(wf 'https://example.org/engine/movegen.rs')"
check 2 'curl bare URL'        "$(ba "curl $GH/blob/master/src/search.cpp")"
check 2 'curl quoted URL'      "$(ba "curl '$GH/blob/master/src/search.cpp'")"
check 2 'wget .diff'           "$(ba "wget -O /tmp/x \\\"$GH/pull/9.diff\\\"")"

# --- must block: the same rules with NO source extension ----------------------
# This block is the one that fails when a host or path rule is deleted. Every
# entry names a file the extension list does not know, or no file at all.
check 2 'blob, no extension'   "$(wf "$GH/blob/master/Makefile")"
check 2 'raw view, CMakeLists' "$(wf "$GH/raw/master/CMakeLists.txt")"
check 2 'raw host, no ext'     "$(wf 'https://raw.githubusercontent.com/example/engine/master/CMakeLists.txt')"
check 2 'patch-diff, no ext'   "$(wf 'https://patch-diff.githubusercontent.com/raw/example/engine/pull/123')"
check 2 'codeload, no ext'     "$(wf 'https://codeload.github.com/example/engine/legacy.tar.gz/refs/heads/main')"
check 2 'blame view'           "$(wf "$GH/blame/master/Makefile")"

# --- must block: hostname case is not significant -----------------------------
check 2 'mixed-case raw host'  "$(wf 'https://Raw.GithubUserContent.com/example/engine/master/CMakeLists.txt')"
check 2 'mixed-case blob'      "$(wf 'https://GitHub.com/example/engine/blob/master/Makefile')"

# --- must block: whole-tree downloads -----------------------------------------
check 2 'archive tarball'      "$(wf "$GH/archive/refs/heads/master.tar.gz")"
check 2 'archive zip'          "$(wf "$GH/archive/master.zip")"
check 2 'archive, no ext'      "$(wf "$GH/archive/master")"
check 2 'source zip anywhere'  "$(wf 'https://example.org/engine/releases/download/v1/source.zip')"

# --- must block: forges other than GitHub -------------------------------------
check 2 'gitlab blob'          "$(wf 'https://gitlab.com/example/engine/-/blob/master/CMakeLists.txt')"
check 2 'gitlab raw'           "$(wf 'https://gitlab.com/example/engine/-/raw/master/Makefile')"
check 2 'bitbucket raw'        "$(wf 'https://bitbucket.org/example/engine/raw/master/src/search')"
check 2 'gitea/codeberg src'   "$(wf 'https://codeberg.org/example/engine/src/branch/main/Makefile')"
check 2 'gitlab tree listing'  "$(wf 'https://gitlab.com/example/engine/-/tree/master/src')"
check 2 'github tree listing'  "$(wf "$GH/tree/master/src")"

# --- must block: a fetch with no scheme ---------------------------------------
# curl treats a bare host as http:// and GitHub redirects to https, so requiring
# a scheme in the extractor skipped the check entirely.
check 2 'curl, no scheme'      "$(ba 'curl -sL github.com/example/engine/blob/master/Makefile -o x')"
check 2 'wget raw, no scheme'  "$(ba 'wget -q raw.githubusercontent.com/example/engine/master/CMakeLists.txt')"

# --- must block: gh aimed somewhere else, in every spelling -------------------
check 2 'gh --repo'            "$(ba 'gh issue comment 5 --repo example/engine --body hi')"
check 2 'gh -R'                "$(ba 'gh pr view 5 -R example/engine')"
check 2 'gh -R, quoted'        "$(ba 'gh pr comment 5 -R \"example/engine\" --body hi')"
check 2 'gh --repo, quoted'    "$(ba "gh pr comment 5 --repo 'example/engine' --body hi")"
check 2 'GH_REPO in the env'   "$(ba 'GH_REPO=example/engine gh issue comment 5 --body hi')"
check 2 'gh with a URL arg'    "$(ba 'gh issue comment https://github.com/example/engine/issues/5 --body hi')"

# --- must block: gh api reads that hand over source ---------------------------
# The carve-out for cross-repo GETs exists for the licence check in rule 2. These
# are GETs too, and they return the file.
check 2 'gh api contents'      "$(ba 'gh api repos/example/engine/contents/src/search.cpp --jq .content')"
check 2 'gh api blob'          "$(ba 'gh api repos/example/engine/git/blobs/deadbeef')"
check 2 'gh api tree'          "$(ba 'gh api repos/example/engine/git/trees/master?recursive=1')"
check 2 'gh api tarball'       "$(ba 'gh api repos/example/engine/tarball/master')"

# --- must block: gh api writes ------------------------------------------------
check 2 'gh api cross-repo'    "$(ba 'gh api repos/example/engine/issues/5/comments -f body=hi')"
check 2 'gh api graphql write' "$(ba 'gh api graphql -f query=mutation')"
# The spelling four deny rules in settings.json used to cover. They matched only
# when the flags preceded the path, which is the rarer way to write it; this hook
# catches both orderings, so the rules went rather than sit there looking covered.
check 2 'gh api flags first'   "$(ba 'gh api --method POST repos/example/engine/issues -f title=t')"

# --- must block: addressing a person, even on this repository -----------------
# Rule 3 is not about ownership, and the REST spelling matches no `gh pr comment`
# prefix a permission rule could catch.
if [[ -n "$self" ]]; then
  check 2 'gh api own comment'  "$(ba "gh api repos/$self/issues/5/comments -f body=hi")"
  check 2 'gh api own review'   "$(ba "gh api repos/$self/pulls/12/reviews -f event=APPROVE")"
fi

# --- must block: merging, which is the human's call ---------------------------
check 2 'gh pr merge'          "$(ba 'gh pr merge 12 --squash')"
check 2 'git merge'            "$(ba 'git merge --squash feat/x')"
check 2 'git push to main'     "$(ba 'git push origin main')"
check 2 'git force to main'    "$(ba 'git push --force origin main')"

# --- must pass: discussion, tools, reads --------------------------------------
check 0 'PR discussion page'   "$(wf "$GH/pull/123")"
check 0 'issue page'           "$(wf "$GH/issues/42")"
check 0 'CPW page'             "$(wf 'https://www.chessprogramming.org/Perft_Results')"
check 0 'repo root (clone ok)' "$(wf "$GH")"
check 0 'releases page'        "$(wf "$GH/releases")"
check 0 'git clone tool'       "$(ba "git clone $GH tools/engine")"
check 0 'licence check (GET)'  "$(ba 'gh api repos/example/engine --jq .license.spdx_id')"
check 0 'gh issue create own'  "$(ba 'gh issue create --title t --body b')"

# --- must pass: the ordinary branch workflow ----------------------------------
# A control that obstructs real work ends up switched off, so this half matters
# as much as the half above.
check 0 'push a feature branch' "$(ba 'git push -u origin fix/some-branch')"
# A bare push sends whatever branch the checkout is on, so this vector's answer
# genuinely depends on that. Stating which case is being exercised keeps the
# suite from passing on a feature branch and failing in CI on main, which is
# exactly how the wrong block above reached main in the first place.
branch="$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null)"
if [[ "$branch" == "main" || "$branch" == "master" ]]; then
  check 2 'bare push, on main'  "$(ba 'git push')"
  check 2 'push HEAD, on main'  "$(ba 'git push origin HEAD')"
else
  check 0 'bare push, off main' "$(ba 'git push')"
  check 0 'push HEAD, off main' "$(ba 'git push origin HEAD')"
fi
check 0 'open a PR'             "$(ba 'gh pr create --title t --body b')"
check 0 'read PR checks'        "$(ba 'gh pr checks 12 --json name,bucket')"
check 0 'pull main ff-only'     "$(ba 'git switch main && git pull --ff-only')"
check 0 'build and test'        "$(ba 'zig build test && zig build')"
check 0 'run the engine'        "$(ba './zig-out/bin/koji epd testdata/perft.epd')"

# --- must pass: things that merely look like the patterns above ---------------
# `grep -R <path>` is not `gh -R <owner>/<repo>`, and a word containing "gh" is
# not the gh command. Both were wrong blocks.
check 0 'grep -R beside gh'     "$(ba 'gh --version; grep -R src/main .')"
check 0 'grep -R alone'         "$(ba 'grep -R max_moves src/')"
check 0 'a word containing gh'  "$(ba 'grep -rn highlight docs/')"
check 0 'local path, not a URL' "$(ba 'bash .claude/hooks/guard_test.sh')"
if [[ -n "$self" ]]; then
  check 0 'gh api write to self' "$(ba "gh api repos/$self/issues -f title=t")"
fi

if [[ "$fail" == 0 ]]; then
  echo "guard_test: all $checked vectors pass"
else
  echo "guard_test: FAILURES above ($checked vectors run)"
  exit 1
fi
