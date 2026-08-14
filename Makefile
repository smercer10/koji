# Thin wrapper over `zig build`, existing only to satisfy the OpenBench build
# contract. Day-to-day work should use `zig build` directly.
#
# OpenBench invokes:  make EXE=Engine-ABCDEFGH
# and then expects a binary with exactly that name in this directory.
#
# It also passes CC= and CXX=. Zig ships its own backend and does not need them;
# make absorbs them as ordinary variable overrides, so they are accepted and
# ignored rather than being an error.

EXE      ?= koji
ZIG      ?= zig
OPTIMIZE ?= ReleaseFast

# -Dcpu=native is right here: OpenBench workers compile on the machine that runs
# the games. It must not change the node count — see the bench invariant in
# CLAUDE.md.
CPU ?= native

# EVALFILE is part of the OpenBench contract once a network exists. Phase 4 adds
# the matching -Devalfile build option; until then there is nothing to point at.

.PHONY: all bench test clean

all:
	$(ZIG) build -Doptimize=$(OPTIMIZE) -Dcpu=$(CPU)
	cp -f zig-out/bin/koji $(EXE)

bench: all
	./$(EXE) bench

# Built for the same CPU as `all`. This is the only target that could catch a
# codegen divergence the native build has and a generic one does not, which is
# exactly what the bench invariant above is about — so it is the last target that
# should be built generic.
test:
	$(ZIG) build test -Dcpu=$(CPU)

clean:
	rm -rf zig-out .zig-cache $(EXE)
