#!/usr/bin/env bash
# Stop hook: refuse to end the turn on a broken build.
#
# This saves an entire wasted turn every time an agent declares done on code that
# does not compile or whose tests fail. Warm `zig build test` is well under a
# second, and it costs zero tokens when it passes.
#
# Shallow perft lives inside `zig build test`, so movegen correctness is gated
# here for free. Deep perft is in `test-slow` and deliberately stays out.
set -uo pipefail

input="$(cat)"

# Claude Code re-runs Stop hooks after a block. Without this guard, a genuinely
# unfixable failure would loop forever.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

# --porcelain catches new untracked .zig files too; `git diff` alone would miss
# exactly the case where a whole new module was added.
if ! git status --porcelain -- '*.zig' | grep -q .; then
  exit 0
fi

if ! output="$(zig build test 2>&1)"; then
  {
    echo "zig build test failed — fix this before ending the turn:"
    echo
    echo "$output"
  } >&2
  exit 2
fi

exit 0
