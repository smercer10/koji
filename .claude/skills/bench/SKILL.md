---
name: bench
description: Measure a speed change (movegen, data layout, SIMD) where SPRT is the wrong instrument. Includes reading the generated assembly.
---

# Bench — the speed test

For changes that should be Elo-neutral but faster: movegen, data layout, SIMD, memory access.
SPRT would need tens of thousands of games to resolve a 3% speedup; `bench` resolves it in seconds.

## A/B the same binary from two commits

```
git switch main   && zig build && cp zig-out/bin/koji /tmp/koji-base
git switch <feat> && zig build && cp zig-out/bin/koji /tmp/koji-test
```

Then, for each, **enough repetitions to see the variance**:

```
for i in $(seq 10); do /tmp/koji-base bench; done
for i in $(seq 10); do /tmp/koji-test bench; done
```

Report nodes/sec for both **with the spread**, not a single number.

**A single-run comparison is not weak evidence — it is no evidence.** Run-to-run noise on this
machine is comfortably larger than most real wins.

Pin the CPU governor before measuring, or the result is a measurement of thermal luck:

```
sudo cpupower frequency-set -g performance
```

Add cycle-level data where the wall clock is ambiguous:

```
perf stat -e cycles,instructions,branch-misses,cache-misses /tmp/koji-test bench
```

## Then read the assembly

This is the step that closes the gap the docs cannot. Neither the langref nor the std source tells
you what is *fast* — only what is legal. When a hot-path change is supposed to lower to specific
instructions, **verify that it did** rather than assuming:

```
objdump -d zig-out/bin/koji | less
```

(For a single function, `objdump -d --disassemble=<mangled name>`; find the name with
`objdump -t zig-out/bin/koji | grep <fn>`. Bare `zig build-obj src/<file>.zig` does not work here —
modules import `build_options`, which only `zig build` provides.)

Concretely: did that `@Vector(16, i16)` become one `vpaddw`? Did `@branchHint` actually reorder the
block? Did the bounds check vanish under ReleaseFast? Did the comptime table get materialised as
constant data, or is it being computed at runtime?

This is what "benchmark, never assume" means in the cases where the effect is smaller than the
noise.

## Timing a `go` from a script

Hold stdin open. Piping a transcript that ends in `quit` aborts the search the moment it starts —
the reader reaches `quit` and joins — and the run still prints plausible `info` lines from the
depths it did reach, so the numbers look real. Send the commands, sleep past the search, *then*
send `quit`.

## Record it

**Most bench runs do not earn a testlog entry.** Read the admission bar at the top of
`docs/testlog.md` before appending: a bench that only confirms nothing moved is already asserted by
the commit's `Bench:` line and checked by CI, and a figure regenerable from `main` on demand belongs
in ROADMAP as something to re-run, not here as a number. A measured *effect* — instructions,
time-to-depth, an ablation a later change must beat — is what earns one.

If a change alters the bench **node count**, it is not a speed change — it changed the search, and
it needs an SPRT.
