#!/usr/bin/env bash
# Stop hook: refuse to end the turn on a broken build.
#
# This saves an entire wasted turn every time an agent declares done on code that
# does not compile or whose tests fail. Warm `zig build test` is well under a
# second (CLAUDE.md carries the figure), and it costs zero tokens when it passes.
#
# Shallow perft lives inside `zig build test`, so movegen correctness is gated
# here for free, and since that step also depends on the exe compiling, "green"
# here means the engine builds as well. Deep perft is in `test-slow` and
# deliberately stays out.
set -uo pipefail

input="$(cat)"

# Claude Code re-runs Stop hooks after a block. Without this guard, a genuinely
# unfixable failure would loop forever.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]]; then
  exit 0
fi

# Fail closed. `set -u` on a bare $CLAUDE_PROJECT_DIR aborted the script at exit
# 1, and a Stop hook only blocks on exit 2 -- so the one script whose whole job
# is "do not end the turn on a broken build" ended the turn silently whenever its
# environment was not what it expected.
root="${CLAUDE_PROJECT_DIR:-.}"
if ! cd "$root" 2>/dev/null || ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "gate.sh: '$root' is not a git checkout, so the build gate did not run." >&2
  exit 2
fi

# Run unconditionally. This used to fire only on uncommitted *.zig changes, which
# missed on both sides: the documented workflow ends a turn with the work
# committed and pushed, so the gate no-opped at exactly the moment it existed
# for; and testdata/perft.epd is @embedFile'd into the test binary and *is* the
# perft oracle, so editing a node count there changed what the tests assert while
# matching no pathspec. Deciding what does and does not affect the build is a
# second copy of the build graph. Running it is cheaper than maintaining that.
if ! output="$(zig build test 2>&1)"; then
  {
    echo "zig build test failed — fix this before ending the turn:"
    echo
    echo "$output"
  } >&2
  exit 2
fi

exit 0
