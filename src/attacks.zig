//! koji — attack sets and board geometry.
//!
//! Three groups, in the order they appear: leaper attacks and the square-pair
//! geometry movegen reasons about (both occupancy-independent, so both are plain
//! comptime tables), then the sliding-piece attacks that are the file's bulk —
//! the rook/bishop attack set for any blocker occupancy, one table lookup each.
//!
//! Both index schemes share the masks, the tables and the fill code; only the
//! occupancy→index step differs:
//!   pext  — BMI2 hardware bit-extract, collision-free by construction.
//!   magic — (occ & mask) * magic >> shift perfect hash. The constants are our
//!           own, found by the seeded search in `searchMagics` — which stays
//!           test-only: a startup search measured 185ms–2.7s (testlog), all of
//!           it avoidable, and the test regenerating the constants and comparing
//!           keeps the hardcoded set provably in sync with the search.
//! The scheme is fixed at comptime from the build target (see `active_scheme`):
//! no per-lookup dispatch in what will be the hottest load in the engine. Tables
//! are "fancy" (per-square sized) rather than plain: same measured speed on
//! modern hardware (Purves, 2010), 840KB instead of 2.25MB.
//
// origin: magic bitboards — Lasse Hansen, CCC, 14 Jun 2006
//         via https://www.chessprogramming.org/Magic_Bitboards
// origin: fancy per-square-sized tables — Pradu Kannan, CCC, 23 Aug 2006
//         via https://www.chessprogramming.org/Magic_Bitboards
// origin: PEXT bitboards — Zach Wegner, TalkChess, 9 Sep 2011
//         via https://www.chessprogramming.org/BMI2

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const board = @import("board.zig");
const Bitboard = board.Bitboard;
const Color = board.Color;
const Square = board.Square;

// --- leapers -----------------------------------------------------------------------
//
// Nothing here depends on occupancy, so each is a straight comptime table built
// from the masked directional shifts in `board.zig` — the masking is what keeps a
// knight on the h-file off the a-file.
//
// origin: knight and king attack lookup tables — unclear (folklore; CPW presents
//         both patterns with no attributed author)
//         via https://www.chessprogramming.org/Knight_Pattern
// origin: set-wise pawn attacks by parallel shift — unclear (folklore; CPW's page
//         is community-authored, crediting no inventor)
//         via https://www.chessprogramming.org/Pawn_Attacks_(Bitboards)

pub const knight_attacks: [64]Bitboard = blk: {
    @setEvalBranchQuota(10_000);
    var t: [64]Bitboard = @splat(0);
    for (&t, 0..) |*a, i| {
        const b = squareBit(i);
        // Two of one direction then one of the other, eight ways. Each shift
        // masks its own wrapping file, so composing them cannot teleport.
        a.* = board.north(board.north(board.east(b))) | board.north(board.north(board.west(b))) |
            board.south(board.south(board.east(b))) | board.south(board.south(board.west(b))) |
            board.east(board.east(board.north(b))) | board.east(board.east(board.south(b))) |
            board.west(board.west(board.north(b))) | board.west(board.west(board.south(b)));
    }
    break :blk t;
};

pub const king_attacks: [64]Bitboard = blk: {
    @setEvalBranchQuota(10_000);
    var t: [64]Bitboard = @splat(0);
    for (&t, 0..) |*a, i| {
        const b = squareBit(i);
        a.* = board.north(b) | board.south(b) | board.east(b) | board.west(b) |
            board.northEast(b) | board.northWest(b) | board.southEast(b) | board.southWest(b);
    }
    break :blk t;
};

/// Squares a pawn of the given color attacks from each square. Indexed by
/// `@intFromEnum(Color)`.
pub const pawn_attacks: [2][64]Bitboard = blk: {
    var t: [2][64]Bitboard = @splat(@splat(0));
    for (0..64) |i| {
        const b = squareBit(i);
        t[@intFromEnum(Color.white)][i] = board.northEast(b) | board.northWest(b);
        t[@intFromEnum(Color.black)][i] = board.southEast(b) | board.southWest(b);
    }
    break :blk t;
};

/// `Square.bit` by index, for the table builders that already loop over `0..64`
/// and would otherwise pay an enum bounds check per square at comptime.
fn squareBit(i: usize) Bitboard {
    return @as(Bitboard, 1) << @intCast(i);
}

/// Every square attacked by a whole set of pawns at once — one pair of shifts
/// instead of a loop over the set, which is what movegen wants for the king
/// danger sweep.
pub fn pawnAttacksSet(comptime c: Color, pawns: Bitboard) Bitboard {
    return if (c == .white)
        board.northEast(pawns) | board.northWest(pawns)
    else
        board.southEast(pawns) | board.southWest(pawns);
}

// --- square-pair geometry ----------------------------------------------------------
//
// origin: 64x64 in-between table — unclear (folklore; CPW documents the
//         "arrRectangular" two-dimensional lookup as the common approach and
//         credits no inventor)
//         via https://www.chessprogramming.org/Square_Attacked_By
// origin: the full-line companion table — unclear; CPW has no page for it, and it
//         follows directly from the empty-board attack sets it is built from
//         via https://www.chessprogramming.org/On_an_empty_Board

/// Squares strictly between two aligned squares, and empty for any pair that is
/// not on a shared rank, file or diagonal — including a square with itself. Under
/// single check, `between[ksq][checker] | checker.bit()` is exactly the set an
/// evasion may land on: block anywhere along the ray, or take the checker. A
/// knight or pawn checker is never aligned with the king, so the empty result
/// leaves capture as the only option with no branch needed.
pub const between: [64][64]Bitboard = blk: {
    @setEvalBranchQuota(50_000);
    var t: [64][64]Bitboard = @splat(@splat(0));
    for (0..64) |i| {
        for (.{ Slider.bishop, Slider.rook }) |s| {
            for (shiftFns(s)) |shift| {
                // Walk outward, remembering the squares already stepped over:
                // that trail *is* the in-between set for wherever we land next.
                var trail: Bitboard = 0;
                var b = shift(squareBit(i));
                while (b != 0) : (b = shift(b)) {
                    t[i][@ctz(b)] = trail;
                    trail |= b;
                }
            }
        }
    }
    break :blk t;
};

/// The whole rank, file or diagonal through two aligned squares, edge to edge and
/// including both; empty when they are not aligned. `line[ksq][sq]` is precisely
/// where a piece pinned against the king on `ksq` is still allowed to go — it may
/// shuffle along the pin and it may capture the pinner, so a pin restricts a piece
/// rather than freezing it.
pub const line: [64][64]Bitboard = blk: {
    @setEvalBranchQuota(50_000);
    var t: [64][64]Bitboard = @splat(@splat(0));
    for (0..64) |i| {
        // Opposite directions form one line, so they are accumulated together.
        for (.{
            .{ &board.north, &board.south },
            .{ &board.east, &board.west },
            .{ &board.northEast, &board.southWest },
            .{ &board.northWest, &board.southEast },
        }) |axis| {
            var whole: Bitboard = squareBit(i);
            for (axis) |shift| {
                var b = shift(squareBit(i));
                while (b != 0) : (b = shift(b)) whole |= b;
            }
            var rest = whole & ~squareBit(i);
            while (rest != 0) : (rest &= rest - 1) t[i][@ctz(rest)] = whole;
        }
    }
    break :blk t;
};

// --- sliders -----------------------------------------------------------------------

pub const Scheme = enum { pext, magic };
pub const Slider = enum(u1) { bishop, rook };

const has_bmi2 = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .bmi2);

/// The BMI2 feature flag alone does not pick the fast path: Excavator and
/// Zen 1/2 report BMI2 but microcode PEXT (~18 cycles vs ~3 on Zen 3+/Haswell+),
/// slower than the multiply it replaces — they take the magic path. Comptime is
/// exact for native builds (dev machine, CI, OpenBench workers all compile
/// locally); a distributed generic binary needs a one-time runtime CPUID check
/// instead — deferred to the first public release (ROADMAP, Phase 2).
pub const active_scheme: Scheme = blk: {
    if (!has_bmi2) break :blk .magic;
    const slow_pext = [_]*const std.Target.Cpu.Model{
        &std.Target.x86.cpu.bdver4,
        &std.Target.x86.cpu.znver1,
        &std.Target.x86.cpu.znver2,
    };
    for (slow_pext) |m| if (builtin.cpu.model == m) break :blk .magic;
    break :blk .pext;
};

// --- masks and table layout (comptime) -----------------------------------------

const Entry = struct {
    /// Relevant occupancy: the rays excluding their final edge square — a blocker
    /// there changes nothing, the square is reached either way. This is what keeps
    /// the per-square occupancy space down to at most 2^12.
    mask: Bitboard,
    /// This square's slice of the piece's attack table starts here.
    offset: u32,
    /// 64 - popCount(mask); the magic scheme's downshift.
    shift: u6,
};

const Meta = struct { entries: [64]Entry, size: u32 };

fn shiftFns(comptime s: Slider) [4]*const fn (Bitboard) Bitboard {
    return switch (s) {
        .bishop => .{ &board.northEast, &board.northWest, &board.southEast, &board.southWest },
        .rook => .{ &board.north, &board.south, &board.east, &board.west },
    };
}

/// Ray-scan reference: walk each direction, stop on (and include) the first
/// blocker. Fills the tables, and is the oracle every scheme is tested against.
pub fn sliderAttacksSlow(comptime s: Slider, sq: Square, occ: Bitboard) Bitboard {
    var attacks: Bitboard = 0;
    inline for (shiftFns(s)) |shift| {
        var b = shift(sq.bit());
        while (b != 0) {
            attacks |= b;
            if (b & occ != 0) break;
            b = shift(b);
        }
    }
    return attacks;
}

fn relevantMask(comptime s: Slider, sq: Square) Bitboard {
    var mask: Bitboard = 0;
    inline for (shiftFns(s)) |shift| {
        var b = shift(sq.bit());
        while (shift(b) != 0) : (b = shift(b)) mask |= b;
    }
    return mask;
}

fn makeMeta(comptime s: Slider) Meta {
    @setEvalBranchQuota(100_000);
    var meta: Meta = .{ .entries = undefined, .size = 0 };
    for (&meta.entries, 0..) |*e, i| {
        const mask = relevantMask(s, @enumFromInt(i));
        e.* = .{ .mask = mask, .offset = meta.size, .shift = @intCast(64 - @popCount(mask)) };
        meta.size += @as(u32, 1) << @intCast(@popCount(mask));
    }
    return meta;
}

const bishop_meta = makeMeta(.bishop);
const rook_meta = makeMeta(.rook);

// The published fancy-table sizes; a mask off by one square lands here, not in
// a rare-position perft divergence three tasks from now.
comptime {
    assert(bishop_meta.size == 5248);
    assert(rook_meta.size == 102_400);
}

inline fn metaOf(comptime s: Slider) *const Meta {
    return switch (s) {
        .bishop => &bishop_meta,
        .rook => &rook_meta,
    };
}

// --- tables and probes ----------------------------------------------------------

var bishop_table: [bishop_meta.size]Bitboard = undefined;
var rook_table: [rook_meta.size]Bitboard = undefined;

inline fn tableOf(comptime s: Slider) []Bitboard {
    return switch (s) {
        .bishop => &bishop_table,
        .rook => &rook_table,
    };
}

/// Our own constants, printed once from `searchMagics` (seed "koji") — nothing
/// copied from published tables, and any valid set produces identical attack
/// sets anyway. The "hardcoded magics" test re-runs the search and compares, so
/// this table cannot drift from the code that produced it; to regenerate after
/// changing the search, print `searchMagics()` from a test.
const magics: [2][64]u64 = .{
    .{
        0x0802084218044100, 0x4020112242004000,
        0x20b000c681020000, 0x9004410020102100,
        0x2004242004000804, 0x2000900460800000,
        0x0801080202a00004, 0x0309a20910080208,
        0x4080085014080050, 0x4002088104189204,
        0x10081001020c2008, 0x4008082041508035,
        0x0000440420020136, 0x5023010109400201,
        0x00480c0a08121888, 0x2440802421082809,
        0x008a402020042082, 0x0024022044008a10,
        0x10020401080a0081, 0x0008218104010050,
        0x0004001211200010, 0x4021000180a00900,
        0x8800800042482000, 0x0100232084040201,
        0x0284628040480110, 0x6514210002084100,
        0x0008241408004c00, 0x8000808048020003,
        0x022b010000704000, 0x0108084116004200,
        0x000252008c09110a, 0x42411a0001108080,
        0x0010042080040809, 0x8002026100502903,
        0x2400403000081044, 0x0020080800120a00,
        0x0040004100001100, 0x6440880081811002,
        0x0822009200891804, 0x2004441220104300,
        0x420802821021a100, 0x000088a450002060,
        0x0002082804082800, 0x0000044202210804,
        0x5c00100210101201, 0x8002204053000080,
        0x0844ac0884042200, 0x000248020024208a,
        0x0002421220202000, 0x14002d0110700000,
        0x8120810041100080, 0x0220010104090008,
        0x8060040861044000, 0x8000420488088000,
        0x0a10200208b20242, 0x0228301401a32810,
        0x04820082181a0201, 0x0000008208010480,
        0x004400288400a204, 0x2c00c00100208800,
        0x8800000040050104, 0x0080821202105100,
        0x2000420298210100, 0x8020200424802140,
    },
    .{
        0x8080008160184000, 0x0280200080400312,
        0x0100084500102000, 0x8880080004801000,
        0x4600200410380200, 0x3600081409220010,
        0x1180010001800600, 0x008003000940a080,
        0x0001800040022080, 0x0082404010002000,
        0x2811002005004010, 0x0208808008001000,
        0x0000808004000800, 0x0200800200040080,
        0x0404000241240810, 0x010100110005804a,
        0x0280024004200040, 0x0440002010002800,
        0x0080110020010040, 0x0188008010000880,
        0xc008008004000881, 0x4208808002000400,
        0x2040040008100201, 0x8820220020408104,
        0x0120c0018000a098, 0x4680500040002000,
        0x0110008080102001, 0x88082012000a0042,
        0x0820050100080010, 0x8004040080020080,
        0x0000010080800200, 0xc10a112200004084,
        0x0020400020800088, 0x0005024a02002180,
        0x0200200101001040, 0x40007000a9002100,
        0x0123810800800400, 0x8014000480800200,
        0x0000100184000802, 0x0200008402000041,
        0x8200800440048022, 0x0410004020084008,
        0x1000200011010040, 0x200a100409010020,
        0x0011000800330004, 0x0002000804010100,
        0x0000018810040002, 0x2000008041020004,
        0xa480804021020200, 0x0810004000200040,
        0x0002a00082100680, 0x4000100280880480,
        0x0008020004004040, 0x0a01000814000300,
        0x0080012208308400, 0x0406800100004080,
        0x0048201440800101, 0x2040001900402081,
        0x0000102000400901, 0x0013011000082005,
        0x8c03001008000205, 0x0082001008040102,
        0x0002100228088144, 0x0004138021040242,
    },
};

/// BMI2: gathers the bits of `src` selected by `mask` into the low result bits.
/// Every reference is comptime-gated on `has_bmi2`, so non-BMI2 targets never
/// assemble this.
inline fn pext(src: u64, mask: u64) u64 {
    return asm ("pext %[mask], %[src], %[ret]"
        : [ret] "=r" (-> u64),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}

inline fn tableIndex(comptime s: Slider, comptime scheme: Scheme, sq: Square, occ: Bitboard) usize {
    const e = metaOf(s).entries[@intFromEnum(sq)];
    switch (scheme) {
        .pext => return @intCast(pext(occ, e.mask)),
        .magic => {
            const magic = magics[@intFromEnum(s)][@intFromEnum(sq)];
            return @intCast(((occ & e.mask) *% magic) >> e.shift);
        },
    }
}

inline fn lookup(comptime s: Slider, sq: Square, occ: Bitboard) Bitboard {
    assert(initialized);
    const e = metaOf(s).entries[@intFromEnum(sq)];
    return tableOf(s)[e.offset + tableIndex(s, active_scheme, sq, occ)];
}

pub fn bishopAttacks(sq: Square, occ: Bitboard) Bitboard {
    return lookup(.bishop, sq, occ);
}

pub fn rookAttacks(sq: Square, occ: Bitboard) Bitboard {
    return lookup(.rook, sq, occ);
}

// --- table fill -------------------------------------------------------------------

/// Visits every blocker subset of the square's mask and stores its ray-scanned
/// attack set at whatever index the scheme assigns. Fill and probe share
/// `tableIndex`, so they cannot disagree.
fn fillTable(comptime s: Slider, comptime scheme: Scheme, table: []Bitboard) void {
    for (metaOf(s).entries, 0..) |e, i| {
        const sq: Square = @enumFromInt(i);
        // origin: Carry-Rippler subset traversal — unclear (folklore)
        //         via https://www.chessprogramming.org/Traversing_Subsets_of_a_Set
        var occ: Bitboard = 0;
        while (true) {
            table[e.offset + tableIndex(s, scheme, sq, occ)] = sliderAttacksSlow(s, sq, occ);
            occ = (occ -% e.mask) & e.mask;
            if (occ == 0) break;
        }
    }
}

// --- magic search (test-only — see the doc on `magics`) ----------------------------

const magic_seed: u64 = 0x6b6f_6a69; // "koji"

/// Sparse random candidates, validated against every subset of the mask; a
/// destructive collision (same index, different attack set) rejects the
/// candidate. Deterministic via the fixed seed, so every run reproduces the
/// hardcoded table above.
// origin: random-sparse-candidate search — Tord Romstad
//         via https://www.chessprogramming.org/Looking_for_Magics
fn searchMagics() [2][64]u64 {
    var found: [2][64]u64 = undefined;
    var rng: std.Random.SplitMix64 = .init(magic_seed);
    inline for (.{ Slider.bishop, Slider.rook }) |s| {
        for (0..64) |i| {
            found[@intFromEnum(s)][i] = findMagic(s, @enumFromInt(i), &rng);
        }
    }
    return found;
}

fn findMagic(comptime s: Slider, sq: Square, rng: *std.Random.SplitMix64) u64 {
    const e = metaOf(s).entries[@intFromEnum(sq)];
    const size = @as(usize, 1) << @intCast(@popCount(e.mask));

    // Enumerate the subsets and their attacks once; candidate trials then only
    // multiply and compare.
    var occs: [4096]Bitboard = undefined;
    var atts: [4096]Bitboard = undefined;
    var n: usize = 0;
    var occ: Bitboard = 0;
    while (true) {
        occs[n] = occ;
        atts[n] = sliderAttacksSlow(s, sq, occ);
        n += 1;
        occ = (occ -% e.mask) & e.mask;
        if (occ == 0) break;
    }
    assert(n == size);

    // Generation counters instead of clearing `used` between candidates: the
    // ~1.4M trials make the per-candidate memset 93% of the whole search
    // (measured: 2.7s -> 185ms, testlog 2026-08-12).
    var used: [4096]Bitboard = undefined;
    var age: [4096]u64 = @splat(0);
    var epoch: u64 = 0;

    while (true) {
        const magic = rng.next() & rng.next() & rng.next();
        // Romstad's filter: a candidate that doesn't spread the mask's high
        // bits can't be a magic; skip it before paying for the scan.
        if (@popCount((e.mask *% magic) & 0xff00_0000_0000_0000) < 6) continue;
        epoch += 1;
        const ok = for (occs[0..size], atts[0..size]) |o, a| {
            const idx = (o *% magic) >> e.shift;
            if (age[idx] != epoch) {
                age[idx] = epoch;
                used[idx] = a;
            } else if (used[idx] != a) break false;
        } else true;
        if (ok) return magic;
    }
}

// --- init -------------------------------------------------------------------------

var initialized = false;

/// Fills the attack tables. Called once from main() before any command runs;
/// idempotent, not thread-safe.
pub fn init() void {
    if (initialized) return;
    initialized = true;
    fillTable(.bishop, active_scheme, tableOf(.bishop));
    fillTable(.rook, active_scheme, tableOf(.rook));
}

// --- tests ------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "leapers reach the right squares and never wrap the board edge" {
    // Centre squares have the full pattern; corners have the fraction that fits.
    try expectEqual(@as(u7, 8), @popCount(knight_attacks[@intFromEnum(Square.e4)]));
    try expectEqual(@as(u7, 2), @popCount(knight_attacks[@intFromEnum(Square.a1)]));
    try expectEqual(@as(u7, 3), @popCount(knight_attacks[@intFromEnum(Square.b1)]));
    try expectEqual(@as(u7, 4), @popCount(knight_attacks[@intFromEnum(Square.b2)]));
    try expectEqual(@as(u7, 8), @popCount(king_attacks[@intFromEnum(Square.e4)]));
    try expectEqual(@as(u7, 3), @popCount(king_attacks[@intFromEnum(Square.a1)]));
    try expectEqual(@as(u7, 5), @popCount(king_attacks[@intFromEnum(Square.a4)]));

    try expectEqual(
        Square.d2.bit() | Square.f2.bit() | Square.c3.bit() | Square.g3.bit() |
            Square.c5.bit() | Square.g5.bit() | Square.d6.bit() | Square.f6.bit(),
        knight_attacks[@intFromEnum(Square.e4)],
    );
    try expectEqual(Square.b3.bit() | Square.c2.bit(), knight_attacks[@intFromEnum(Square.a1)]);

    // A leaper on either edge file must stay on its own side of the board.
    for (0..64) |i| {
        const sq: Square = @enumFromInt(i);
        const wrap = if (sq.file() == 0) board.file_h else if (sq.file() == 7) board.file_a else continue;
        try expectEqual(@as(Bitboard, 0), knight_attacks[i] & wrap);
        try expectEqual(@as(Bitboard, 0), king_attacks[i] & wrap);
        try expectEqual(@as(Bitboard, 0), pawn_attacks[0][i] & wrap);
        try expectEqual(@as(Bitboard, 0), pawn_attacks[1][i] & wrap);
    }
}

test "pawn attacks: per-square table, set-wise shifts, and the two agree" {
    try expectEqual(Square.d5.bit() | Square.f5.bit(), pawn_attacks[0][@intFromEnum(Square.e4)]);
    try expectEqual(Square.d3.bit() | Square.f3.bit(), pawn_attacks[1][@intFromEnum(Square.e4)]);
    // Only a pawn's own forward diagonals, so rank 1 attacks nothing for black.
    try expectEqual(@as(Bitboard, 0), pawn_attacks[1][@intFromEnum(Square.e1)]);

    // The set-wise form is the union of the per-square form over the whole set.
    var rng: std.Random.SplitMix64 = .init(11);
    for (0..256) |_| {
        const pawns = rng.next();
        inline for (.{ Color.white, Color.black }) |c| {
            var expected: Bitboard = 0;
            var rest = pawns;
            while (rest != 0) : (rest &= rest - 1) {
                expected |= pawn_attacks[@intFromEnum(c)][@ctz(rest)];
            }
            try expectEqual(expected, pawnAttacksSet(c, pawns));
        }
    }
}

/// The in-between set derived from nothing but the ray scan: the squares a slider
/// on `a` reaches with `x` blocking it, intersected with the same seen from `x`.
/// Only the segment joining the two survives that — rays running outward past
/// either square are in one set but not the other. Empty when they are unaligned.
fn betweenSlow(a: usize, x: usize) Bitboard {
    inline for (.{ Slider.rook, Slider.bishop }) |s| {
        if (sliderAttacksSlow(s, @enumFromInt(a), 0) & squareBit(x) != 0) {
            return sliderAttacksSlow(s, @enumFromInt(a), squareBit(x)) &
                sliderAttacksSlow(s, @enumFromInt(x), squareBit(a));
        }
    }
    return 0;
}

test "between and line describe the same geometry the ray scan does" {
    // Both are read as `[king][other]`, so both directions of every pair matter.
    for (0..64) |a| {
        for (0..64) |x| {
            try expectEqual(betweenSlow(a, x), between[a][x]);
            try expectEqual(between[a][x], between[x][a]);
            try expectEqual(line[a][x], line[x][a]);
            // Neither endpoint is ever in the in-between set.
            try expectEqual(@as(Bitboard, 0), between[a][x] & (squareBit(a) | squareBit(x)));

            // Alignment, decided independently of both tables: two distinct
            // squares are aligned exactly when one lies in the other's
            // empty-board slider set.
            const aligned = a != x and
                (sliderAttacksSlow(.rook, @enumFromInt(a), 0) |
                    sliderAttacksSlow(.bishop, @enumFromInt(a), 0)) & squareBit(x) != 0;
            if (!aligned) {
                try expectEqual(@as(Bitboard, 0), line[a][x]);
                continue;
            }

            // Aligned: the line holds both endpoints and everything between them.
            try expect(line[a][x] & squareBit(a) != 0 and line[a][x] & squareBit(x) != 0);
            try expectEqual(between[a][x], between[a][x] & line[a][x]);
        }
    }
}

test "between and line on worked examples" {
    try expectEqual(Square.b1.bit() | Square.c1.bit() | Square.d1.bit(), between[@intFromEnum(Square.a1)][@intFromEnum(Square.e1)]);
    try expectEqual(Square.b2.bit() | Square.c3.bit(), between[@intFromEnum(Square.a1)][@intFromEnum(Square.d4)]);
    // Adjacent squares have nothing between them; a knight's leap is unaligned.
    try expectEqual(@as(Bitboard, 0), between[@intFromEnum(Square.a1)][@intFromEnum(Square.a2)]);
    try expectEqual(@as(Bitboard, 0), between[@intFromEnum(Square.a1)][@intFromEnum(Square.b3)]);
    try expectEqual(@as(Bitboard, 0), line[@intFromEnum(Square.a1)][@intFromEnum(Square.b3)]);

    // A line runs edge to edge, not just between the two squares.
    try expectEqual(board.rankMask(0), line[@intFromEnum(Square.a1)][@intFromEnum(Square.e1)]);
    try expectEqual(board.fileMask(4), line[@intFromEnum(Square.e2)][@intFromEnum(Square.e7)]);
    try expectEqual(
        Square.a1.bit() | Square.b2.bit() | Square.c3.bit() | Square.d4.bit() |
            Square.e5.bit() | Square.f6.bit() | Square.g7.bit() | Square.h8.bit(),
        line[@intFromEnum(Square.c3)][@intFromEnum(Square.f6)],
    );
    // A square is aligned with nothing, itself included.
    try expectEqual(@as(Bitboard, 0), line[@intFromEnum(Square.e4)][@intFromEnum(Square.e4)]);
}

test "relevant masks: documented bit counts, edge exclusion, table sizes" {
    // Comptime-asserted too, but a test failure reads better than a compile error.
    try expectEqual(@as(u32, 102_400), rook_meta.size);
    try expectEqual(@as(u32, 5248), bishop_meta.size);

    const rook_a1 = rook_meta.entries[@intFromEnum(Square.a1)].mask;
    const rook_e4 = rook_meta.entries[@intFromEnum(Square.e4)].mask;
    const bishop_a1 = bishop_meta.entries[@intFromEnum(Square.a1)].mask;
    const bishop_e4 = bishop_meta.entries[@intFromEnum(Square.e4)].mask;

    try expectEqual(@as(u7, 12), @popCount(rook_a1));
    try expectEqual(@as(u7, 10), @popCount(rook_e4));
    try expectEqual(@as(u7, 6), @popCount(bishop_a1));
    try expectEqual(@as(u7, 9), @popCount(bishop_e4));

    // The ray's terminal square is never part of the hashed occupancy.
    try expectEqual(@as(Bitboard, 0), rook_a1 & (Square.a8.bit() | Square.h1.bit()));
    try expectEqual(@as(Bitboard, 0), rook_e4 & (board.fileMask(4) & (board.rankMask(0) | board.rankMask(7))));
}

test "active scheme agrees with the ray-scan oracle" {
    init();
    var rng: std.Random.SplitMix64 = .init(42);
    for (0..64) |i| {
        const sq: Square = @enumFromInt(i);
        try expectEqual(sliderAttacksSlow(.rook, sq, 0), rookAttacks(sq, 0));
        try expectEqual(sliderAttacksSlow(.bishop, sq, 0), bishopAttacks(sq, 0));
        for (0..256) |_| {
            const occ = rng.next();
            try expectEqual(sliderAttacksSlow(.rook, sq, occ), rookAttacks(sq, occ));
            try expectEqual(sliderAttacksSlow(.bishop, sq, occ), bishopAttacks(sq, occ));
        }
    }
}

/// Fills a scratch table with the given scheme and checks it against the oracle.
/// Exists so *both* schemes stay tested on every machine — otherwise the magic
/// path would be dead code on every PEXT dev box, and its first real run would
/// be on some tester's Zen 2.
fn expectSchemeMatchesOracle(comptime scheme: Scheme) !void {
    inline for (.{ Slider.bishop, Slider.rook }) |s| {
        const table = try std.testing.allocator.alloc(Bitboard, metaOf(s).size);
        defer std.testing.allocator.free(table);
        fillTable(s, scheme, table);

        var rng: std.Random.SplitMix64 = .init(7);
        for (0..64) |i| {
            const sq: Square = @enumFromInt(i);
            const e = metaOf(s).entries[i];
            for (0..128) |_| {
                const occ = rng.next();
                const got = table[e.offset + tableIndex(s, scheme, sq, occ)];
                try expectEqual(sliderAttacksSlow(s, sq, occ), got);
            }
        }
    }
}

test "magic scheme agrees with the oracle on any target" {
    try expectSchemeMatchesOracle(.magic);
}

test "hardcoded magics are exactly what the seeded search finds" {
    const found = searchMagics();
    try std.testing.expectEqualSlices(u64, &magics[0], &found[0]);
    try std.testing.expectEqualSlices(u64, &magics[1], &found[1]);
}

test "pext scheme agrees with the oracle where BMI2 exists" {
    if (comptime has_bmi2) {
        try expectSchemeMatchesOracle(.pext);
    } else return error.SkipZigTest;
}

test "edge blockers are attacked but never hashed" {
    init();
    // Blockers only on the excluded edge squares change nothing: the lookup for
    // a1 with a8/h1 occupied must equal the empty-board attack set and still
    // reach both blockers.
    const occ = Square.a8.bit() | Square.h1.bit();
    const attacks = rookAttacks(.a1, occ);
    try expectEqual(rookAttacks(.a1, 0), attacks);
    try expectEqual((board.file_a | board.rankMask(0)) & ~Square.a1.bit(), attacks);
}
