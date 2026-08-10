#!/usr/bin/env bash
# PostToolUse hook on Edit|Write: format edited Zig files.
#
# Costs zero tokens on success and removes a whole class of trivial formatting
# churn from diffs. Silent by design — if it has something to say, something is
# wrong.
set -uo pipefail

file="$(jq -r '.tool_input.file_path // empty')"

[[ -z "$file" ]] && exit 0
[[ "$file" != *.zig ]] && exit 0
[[ ! -f "$file" ]] && exit 0

# zig fmt on a file with a syntax error exits non-zero and changes nothing. That
# is the model's problem to fix, not the hook's, and `zig build test` will catch
# it at the Stop gate — so stay quiet either way.
zig fmt "$file" >/dev/null 2>&1

exit 0
