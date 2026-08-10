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

# -Dcpu=native is right for a local build and for an OpenBench worker, which
# compiles on the machine that will run the games. It must never change the node
# count: cross-machine bench determinism is what makes SPRT results comparable,
# so every eval path stays integer (see the Phase 4 note in ROADMAP.md).
CPU ?= native

# EVALFILE is part of the OpenBench contract once a network exists. Phase 4 adds
# the matching -Devalfile build option; until then there is nothing to point at.

.PHONY: all bench test clean

all:
	$(ZIG) build -Doptimize=$(OPTIMIZE) -Dcpu=$(CPU)
	cp -f zig-out/bin/koji $(EXE)

bench: all
	./$(EXE) bench

test:
	$(ZIG) build test

clean:
	rm -rf zig-out .zig-cache $(EXE)
