#!/usr/bin/env bash
# Failure-path test for guard.sh. Run after any edit to guard.sh, and from
# /audit at every phase boundary: bash .claude/hooks/guard_test.sh
#
# Vectors live in this file rather than in the invoking command because the
# live hook scans command text -- a probe typed into a session blocks itself.
# Engine names in URLs are placeholders; no real project is referenced.
set -uo pipefail
cd "$(dirname "$0")"
export CLAUDE_PROJECT_DIR="$(cd ../.. && pwd)"

self="$(git -C "$CLAUDE_PROJECT_DIR" remote get-url origin 2>/dev/null |
  sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"

fail=0
check() { # <expected-exit> <description> <json>
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

# --- must block (exit 2): source in any wrapper -------------------------------
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
check 2 'gh --repo cross-repo' "$(ba 'gh issue comment 5 --repo example/engine --body hi')"
check 2 'gh -R cross-repo'     "$(ba 'gh pr view 5 -R example/engine')"
check 2 'gh api path write'    "$(ba 'gh api repos/example/engine/issues/5/comments -f body=hi')"
check 2 'gh api graphql write' "$(ba 'gh api graphql -f query=mutation')"

# --- must pass (exit 0): discussion, tools, reads -----------------------------
check 0 'PR discussion page'   "$(wf "$GH/pull/123")"
check 0 'issue page'           "$(wf "$GH/issues/42")"
check 0 'CPW page'             "$(wf 'https://www.chessprogramming.org/Perft_Results')"
check 0 'repo root (clone ok)' "$(wf "$GH")"
check 0 'git clone tool'       "$(ba "git clone $GH tools/engine")"
check 0 'licence check (GET)'  "$(ba 'gh api repos/example/engine --jq .license.spdx_id')"
check 0 'gh issue create own'  "$(ba 'gh issue create --title t --body b')"
if [[ -n "$self" ]]; then
  check 0 'gh api write to self' "$(ba "gh api repos/$self/issues -f title=t")"
fi

if [[ "$fail" == 0 ]]; then echo "guard_test: all vectors pass"; else exit 1; fi
