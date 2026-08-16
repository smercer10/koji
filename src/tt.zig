//! koji — the transposition table.
//!
//! A dumb container, deliberately. It maps a Zobrist key to what a previous
//! search concluded about that position and knows nothing about what the numbers
//! mean: the mate-score convention, the window the bound is resolved against and
//! the decision to trust an entry at all are `search.zig`'s, which is also what
//! keeps the import graph acyclic.
//!
//! Two things it is responsible for. The first is never handing back an entry
//! that belongs to a different position — see `Entry.key`. The second is being
//! deterministic: `bench` must print the same node count on every run and every
//! machine (CLAUDE.md), and a table whose contents depended on timing or on
//! uninitialised memory would break that before any of the search did.
//
// origin: transposition table — Richard Greenblatt's Mac Hack VI, 1967. CPW:
//         "first used in Greenblatt's program", published as Greenblatt,
//         Eastlake and Crocker, "The Greenblatt Chess Program", 1967. The
//         hashing underneath it is Zobrist's and is credited in `board.zig`.
//         via https://www.chessprogramming.org/Transposition_Table
// origin: exact / lower-bound / upper-bound entry types — unclear (folklore;
//         CPW states the three kinds and their correspondence to PV-, all- and
//         cut-nodes, and names no originator)
//         via https://www.chessprogramming.org/Transposition_Table
// origin: depth-preferred replacement, and aging entries by search — unclear
//         (folklore; CPW's replacement-strategy section describes both with no
//         attribution, while naming authors for the schemes koji does *not*
//         use: the two-tier system to Ken Thompson and Joe Condon, bucket
//         systems to Don Beal and Martin C. Smith, 1996)
//         via https://www.chessprogramming.org/Transposition_Table

const std = @import("std");
const assert = std.debug.assert;

const move = @import("move.zig");
const Move = move.Move;

/// What a stored score claims about the true value of a position. `none` is 0 so
/// that zeroed memory reads as "nothing stored here" — that is what lets `clear`
/// be a `memset` and what makes a freshly allocated table safe to probe before
/// anything has been written to it.
pub const Bound = enum(u2) {
    none = 0,
    /// Fail-low: the true score is *at most* `score`.
    upper,
    /// Fail-high: the true score is *at least* `score`.
    lower,
    /// The search never left its window: `score` is the value itself.
    exact,
};

/// Exactly 16 bytes, and a test says so. Four to a cache line, which is what the
/// bucket experiment filed in ROADMAP would exploit; today it only means an
/// entry never straddles two lines.
pub const Entry = extern struct {
    /// The **whole** Zobrist key, not a truncated signature.
    ///
    /// The usual entry is 8 bytes with 16 key bits, and leans on validating the
    /// stored move against the position before playing it. At a million entries
    /// that scheme verifies about 36 bits, so roughly one probe in 65k that
    /// lands on an occupied slot returns some other position's entry — order a
    /// thousand of them in a 70M-node bench. koji has no pseudo-legality check
    /// to catch those, and "an illegal PV move is never cosmetic" (CLAUDE.md) is
    /// only a usable rule if it is not routinely false. A full key makes the
    /// ordering move legal by construction: same key, same position, up to a
    /// genuine Zobrist collision at ~10^-4 per bench.
    ///
    /// Halving this and adding the check is a real gain — twice the entries in
    /// the same memory — and is filed as its own experiment, where it can be
    /// measured instead of assumed.
    key: u64,
    /// The best move found, and the reason a shallow entry is still worth
    /// having: ordering pays off at any depth, a cutoff only at a sufficient
    /// one. Never read unless `meta.bound != .none`, so the all-zero move that
    /// an empty entry carries is unreachable rather than merely harmless.
    move: Move,
    /// Fits `i16` with room to spare: the widest score in the engine is
    /// `mate_score + 1` = 32001.
    score: i16,
    /// Remaining depth this score was searched to. Signed and 16-bit: `max_ply`
    /// is 128, which an `i8` cannot hold, and quiescence will store depths at or
    /// below zero. The padding it costs was already there.
    depth: i16,
    meta: Meta,

    pub const Meta = packed struct(u8) {
        bound: Bound,
        /// Which search wrote this, low bits only — see `Table.newSearch`.
        generation: u6,
    };
};

pub const Table = struct {
    /// Power-of-two length so indexing is a mask, or empty for a disabled table.
    entries: []align(cache_line) Entry,
    generation: u6,

    /// A table that stores nothing and hits never. Used by every test that is
    /// about plain alpha-beta rather than about the table, and by any caller
    /// that has no allocator — a search with one is slower, never wrong.
    pub const off: Table = .{ .entries = &.{}, .generation = 0 };

    const cache_line = 64;

    /// Allocates the largest power-of-two number of entries that fits in
    /// `megabytes`. Rounding *down* rather than up is what makes `Hash` a
    /// promise: a GUI that says 16 gets at most 16.
    pub fn init(allocator: std.mem.Allocator, megabytes: usize) !Table {
        const wanted = (megabytes << 20) / @sizeOf(Entry);
        const count = std.math.floorPowerOfTwo(usize, wanted);
        if (count == 0) return .off;

        // The alignment is load-bearing, not decoration. At a 16-byte stride an
        // 8-aligned base puts every fourth entry across a cache-line boundary,
        // turning a quarter of all probes into two line fetches.
        var t: Table = .{
            .entries = try allocator.alignedAlloc(Entry, .fromByteUnits(cache_line), count),
            .generation = 0,
        };
        t.clear();
        return t;
    }

    pub fn deinit(t: *Table, allocator: std.mem.Allocator) void {
        if (t.entries.len != 0) allocator.free(t.entries);
        t.* = .off;
    }

    /// Reallocate at a new size, in the megabytes `Hash` speaks. Serves
    /// `setoption name Hash`; the table it leaves is empty, which is what a GUI
    /// asking for a different size means.
    ///
    /// **Allocates before it frees, and the order is the whole point.** koji
    /// advertises `Hash` up to 65536, so a GUI may legally ask for 64GB and be
    /// refused by the OS. Freeing first would answer that request by leaving the
    /// engine with no table at all — it would play on, slower and no less
    /// correct, having lost a table it was using because it was asked for one it
    /// could not have. Failing here changes nothing instead, and the caller keeps
    /// what it had.
    ///
    /// Callers must free with the same allocator they pass here.
    pub fn resize(t: *Table, allocator: std.mem.Allocator, megabytes: usize) !void {
        const fresh: Table = try .init(allocator, megabytes);
        // `init` answers a sub-entry request with a successful `.off`, right for
        // a table asked to be absent and wrong for one that already exists:
        // without this, the lines below free a live table, install the empty one
        // and report success. `applyOption` clamps to `min_hash_mb` and never
        // asks — but this is public API and the clamp is not part of it.
        if (fresh.entries.len == 0 and t.entries.len != 0) return error.OutOfMemory;
        t.deinit(allocator);
        t.* = fresh;
    }

    /// Back to the state `init` leaves: every entry empty, the generation back at
    /// the start. `ucinewgame`, and every `bench` position.
    pub fn clear(t: *Table) void {
        @memset(std.mem.sliceAsBytes(t.entries), 0);
        t.generation = 0;
    }

    /// One `go` is one generation. Entries from an older one are the first thing
    /// replacement throws away: a deep score from three moves ago is about a
    /// position the game has left behind, and holding it in preference to a
    /// shallow one from the search actually running is how a table fills with
    /// answers to questions nobody is asking.
    ///
    /// Six bits, and wrapping is correct rather than tolerated — all the
    /// comparison ever asks is "was this written by the search that is running",
    /// and 64 searches is far past the point where any surviving entry is worth
    /// keeping for its age.
    pub fn newSearch(t: *Table) void {
        t.generation +%= 1;
    }

    fn slot(t: *const Table, key: u64) usize {
        assert(t.entries.len != 0);
        // The keys come from SplitMix64, so the low bits are as good as any.
        return @intCast(key & (t.entries.len - 1));
    }

    /// The entry for `key`, or null if this position has not been stored — or has
    /// been evicted, which is the same thing to a caller.
    pub fn probe(t: *const Table, key: u64) ?Entry {
        if (t.entries.len == 0) return null;
        const entry = t.entries[t.slot(key)];
        if (entry.meta.bound == .none or entry.key != key) return null;
        return entry;
    }

    /// Depth-preferred within a search, always-replace across one: an entry
    /// survives only against a shallower result from the same generation.
    ///
    /// The two halves answer different failures. Without the depth rule a deep
    /// result is thrown away by the next shallow node that happens to collide
    /// with it, and the expensive half of the search is exactly what the table
    /// exists to keep. Without the generation rule nothing deep is ever
    /// replaced, and after a few moves the table is full of entries no line of
    /// the current search can reach.
    pub fn store(
        t: *Table,
        key: u64,
        best: Move,
        score: i16,
        depth: i16,
        bound: Bound,
    ) void {
        assert(bound != .none);
        if (t.entries.len == 0) return;

        const entry = &t.entries[t.slot(key)];
        if (entry.meta.bound != .none and
            entry.meta.generation == t.generation and
            entry.depth > depth) return;

        entry.* = .{
            .key = key,
            .move = best,
            .score = score,
            .depth = depth,
            .meta = .{ .bound = bound, .generation = t.generation },
        };
    }

    /// The size actually allocated, in the megabytes `Hash` speaks. `init` rounds
    /// down to a power of two entries, so this is what a caller *got* rather than
    /// what it asked for — 3MB of request is 2MB of table.
    pub fn allocatedMb(t: *const Table) usize {
        return (t.entries.len * @sizeOf(Entry)) >> 20;
    }

    /// Occupancy in permill, the unit UCI's `info hashfull` wants. Samples the
    /// first thousand entries rather than counting them all: this is only ever
    /// asked between iterations, but walking 16MB to answer it would still be
    /// paid out of the search's cache.
    /// Physical occupancy, **not the current generation's share of it**:
    /// `newSearch` bumps the generation without clearing the table, so a
    /// generation-scoped count reads ~0 on the first `info` line of every `go`
    /// and hides a saturated table — the fault `Info.hashfull` exists to expose.
    /// UCI defines it as "the hash is x permill full".
    pub fn hashfull(t: *const Table) u32 {
        const sample = @min(t.entries.len, 1000);
        if (sample == 0) return 0;
        var used: u32 = 0;
        for (t.entries[0..sample]) |entry| {
            if (entry.meta.bound != .none) used += 1;
        }
        return @intCast(used * 1000 / sample);
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// Any move at all; the table never looks inside one.
const some_move: Move = .init(.e2, .e4, .quiet);

test "an entry is exactly 16 bytes" {
    // Not a preference. Four to a cache line is what makes the bucket experiment
    // in ROADMAP possible without changing the entry, and a field added
    // carelessly would silently cost a line fetch per probe.
    try testing.expectEqual(@as(usize, 16), @sizeOf(Entry));
    try testing.expectEqual(@as(usize, 0), 64 % @sizeOf(Entry));
}

test "a size in megabytes becomes a power of two entries, rounded down" {
    var sixteen: Table = try .init(testing.allocator, 16);
    defer sixteen.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1 << 20), sixteen.entries.len);

    // 3MB is 196,608 entries; the table takes the 131,072 below it rather than
    // the 262,144 above, which would be 4MB for a table that promised 3.
    var three: Table = try .init(testing.allocator, 3);
    defer three.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1 << 17), three.entries.len);
    try testing.expect(three.entries.len * @sizeOf(Entry) <= 3 << 20);

    // Too small to hold a single entry is a disabled table, not a crash.
    var nothing: Table = try .init(testing.allocator, 0);
    defer nothing.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), nothing.entries.len);
}

test "resize gives a table of the new size, empty, and keeps the old one on failure" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1 << 16), t.entries.len);

    t.newSearch();
    t.store(0xabc, some_move, 1, 1, .exact);
    try testing.expect(t.probe(0xabc) != null);

    // Growing, shrinking, and the same round-down `init` applies.
    try t.resize(testing.allocator, 4);
    try testing.expectEqual(@as(usize, 1 << 18), t.entries.len);
    try t.resize(testing.allocator, 3);
    try testing.expectEqual(@as(usize, 1 << 17), t.entries.len);

    // A resized table is a fresh one: the entry above is gone rather than
    // rehashed, and the generation is back at the start.
    try testing.expectEqual(@as(?Entry, null), t.probe(0xabc));
    try testing.expectEqual(@as(u6, 0), t.generation);
    for (t.entries) |entry| try testing.expectEqual(Bound.none, entry.meta.bound);

    // The reason `resize` allocates before it frees. A failing allocation must
    // leave the caller with the table it already had — a UCI engine that answered
    // `setoption name Hash value 65536` by losing its table would then play on
    // with none, which is the one outcome worse than refusing the request.
    const before = t.entries;
    try testing.expectError(error.OutOfMemory, t.resize(testing.failing_allocator, 1));
    try testing.expectEqual(before.ptr, t.entries.ptr);
    try testing.expectEqual(before.len, t.entries.len);

    // A size that rounds to no entries is the same promise: unguarded, `resize`
    // frees the live table, installs an empty one and reports success.
    const kept = t.entries;
    try testing.expectError(error.OutOfMemory, t.resize(testing.allocator, 0));
    try testing.expectEqual(kept.ptr, t.entries.ptr);
    try testing.expectEqual(kept.len, t.entries.len);

    // Asking a table that is already off for nothing is not a loss, so it is
    // allowed: there is no live allocation to protect.
    var absent: Table = .off;
    try absent.resize(testing.allocator, 0);
    try testing.expectEqual(@as(usize, 0), absent.entries.len);
}

test "a fresh table is empty everywhere" {
    // Allocated memory is not zeroed memory, and an entry read as occupied
    // before anything was stored would be a wrong score with a plausible key.
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);

    for (t.entries) |entry| try testing.expectEqual(Bound.none, entry.meta.bound);

    var key: u64 = 1;
    for (0..1000) |_| {
        try testing.expectEqual(@as(?Entry, null), t.probe(key));
        key *%= 0x9e37_79b9_7f4a_7c15;
    }
}

test "a stored entry comes back with every field intact" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);
    t.newSearch();

    t.store(0xdead_beef_cafe_f00d, some_move, -321, 7, .upper);
    const got = t.probe(0xdead_beef_cafe_f00d).?;

    try testing.expectEqual(@as(u64, 0xdead_beef_cafe_f00d), got.key);
    try testing.expectEqual(@as(u16, @bitCast(some_move)), @as(u16, @bitCast(got.move)));
    try testing.expectEqual(@as(i16, -321), got.score);
    try testing.expectEqual(@as(i16, 7), got.depth);
    try testing.expectEqual(Bound.upper, got.meta.bound);
    try testing.expectEqual(t.generation, got.meta.generation);
}

test "a key that collides in the index is not confused for a hit" {
    // The whole safety argument for the ordering move rests on this: two keys
    // that share every index bit must still be told apart.
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);

    const key: u64 = 0x1234_5678_9abc_def0;
    const twin = key ^ (1 << 63); // same slot, different position
    try testing.expectEqual(t.slot(key), t.slot(twin));

    t.store(key, some_move, 100, 4, .exact);
    try testing.expect(t.probe(key) != null);
    try testing.expectEqual(@as(?Entry, null), t.probe(twin));
}

test "replacement keeps the deeper entry within a search and drops it across one" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);
    t.newSearch();

    const key: u64 = 0x0f0f_0f0f_0f0f_0f0f;
    t.store(key, some_move, 100, 8, .exact);

    // Shallower, same search: refused.
    t.store(key, some_move, 200, 3, .exact);
    try testing.expectEqual(@as(i16, 8), t.probe(key).?.depth);

    // Equal depth, same search: taken. The newer search of the same depth saw a
    // better-ordered tree, so its answer is at least as good.
    t.store(key, some_move, 200, 8, .lower);
    try testing.expectEqual(@as(i16, 200), t.probe(key).?.score);
    try testing.expectEqual(Bound.lower, t.probe(key).?.meta.bound);

    // Deeper, same search: taken.
    t.store(key, some_move, 300, 12, .exact);
    try testing.expectEqual(@as(i16, 12), t.probe(key).?.depth);

    // Shallower, next search: taken anyway. Age outranks depth.
    t.newSearch();
    t.store(key, some_move, 400, 1, .upper);
    try testing.expectEqual(@as(i16, 1), t.probe(key).?.depth);
    try testing.expectEqual(@as(i16, 400), t.probe(key).?.score);
}

test "the generation wraps without ever matching a stale entry by accident" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);

    // 64 searches brings the counter back where it started. An entry that
    // survived all of them would then read as current — it cannot here, because
    // any store on that slot in between replaced it, and that is the only way
    // the comparison is ever used.
    const key: u64 = 42;
    t.newSearch();
    const first = t.generation;
    t.store(key, some_move, 10, 30, .exact);

    for (0..64) |_| t.newSearch();
    try testing.expectEqual(first, t.generation);

    // Shallower and, by the counter, from "this" search — so depth decides, and
    // the ancient deep entry wins. Harmless: it is a real score for this exact
    // position, which is all any entry ever claims.
    t.store(key, some_move, 20, 1, .exact);
    try testing.expectEqual(@as(i16, 30), t.probe(key).?.depth);
}

test "clear leaves the table indistinguishable from a fresh one" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);

    t.newSearch();
    t.newSearch();
    var key: u64 = 7;
    for (0..500) |_| {
        t.store(key, some_move, 1, 1, .exact);
        key *%= 0x9e37_79b9_7f4a_7c15;
    }
    try testing.expect(t.hashfull() > 0);

    t.clear();
    try testing.expectEqual(@as(u6, 0), t.generation);
    try testing.expectEqual(@as(u32, 0), t.hashfull());
    key = 7;
    for (0..500) |_| {
        try testing.expectEqual(@as(?Entry, null), t.probe(key));
        key *%= 0x9e37_79b9_7f4a_7c15;
    }
}

test "a disabled table stores nothing, hits never, and does not fault" {
    var t: Table = .off;
    defer t.deinit(testing.allocator);

    t.newSearch();
    t.store(1, some_move, 100, 5, .exact);
    try testing.expectEqual(@as(?Entry, null), t.probe(1));
    try testing.expectEqual(@as(u32, 0), t.hashfull());
    t.clear();
}

test "hashfull counts this search's entries in permill" {
    var t: Table = try .init(testing.allocator, 1);
    defer t.deinit(testing.allocator);
    t.newSearch();

    try testing.expectEqual(@as(u32, 0), t.hashfull());

    // The sample is the first thousand slots, so store into exactly those: with
    // a power-of-two table, key `i` lands in slot `i`.
    for (0..250) |i| t.store(@intCast(i), some_move, 0, 1, .exact);
    try testing.expectEqual(@as(u32, 250), t.hashfull());

    // A new search does not empty the table, so it does not empty this number.
    // Replacement will still take any of these entries — that is a fact about
    // replacement, not about how full the table is.
    t.newSearch();
    try testing.expectEqual(@as(u32, 250), t.hashfull());
}
