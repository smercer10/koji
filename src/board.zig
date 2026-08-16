//! koji — board representation.
//!
//! Hybrid: piece-centric bitboards for the set-wise operations movegen lives on,
//! plus a square-centric mailbox so "what sits on square x" is one byte load
//! instead of a probe over six type bitboards. The mailbox is redundant state;
//! everything that mutates it goes through `put`/`remove`/`movePiece`, which
//! also maintain the Zobrist key, and `consistent()` checks the agreement
//! invariant that make/unmake asserts on every move in Debug builds.
//! Whether the redundancy actually pays is a hypothesis until measured — the
//! ablation is listed under candidate ideas in ROADMAP.md.
//
// origin: bitboards — Georgy Adelson-Velsky et al. 1967, first used in Kaissa
//         via https://www.chessprogramming.org/Bitboards
// origin: redundant bitboard+mailbox hybrid — unclear (folklore)
//         via https://www.chessprogramming.org/Board_Representation

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

// --- bitboards -----------------------------------------------------------------

/// Plain u64, little-endian rank-file: bit 0 = a1, bit 7 = h1, bit 63 = h8.
/// No wrapper struct — the operators on a bare integer *are* the API.
pub const Bitboard = u64;

pub const file_a: Bitboard = 0x0101_0101_0101_0101;
pub const file_h: Bitboard = file_a << 7;

pub fn fileMask(f: u3) Bitboard {
    return file_a << f;
}

pub fn rankMask(r: u3) Bitboard {
    return @as(Bitboard, 0xff) << (@as(u6, r) * 8);
}

// Directional shifts. East/west and the diagonals mask the wrapping file
// *before* shifting so pieces never teleport across the board edge.
pub fn north(b: Bitboard) Bitboard {
    return b << 8;
}
pub fn south(b: Bitboard) Bitboard {
    return b >> 8;
}
pub fn east(b: Bitboard) Bitboard {
    return (b & ~file_h) << 1;
}
pub fn west(b: Bitboard) Bitboard {
    return (b & ~file_a) >> 1;
}
pub fn northEast(b: Bitboard) Bitboard {
    return (b & ~file_h) << 9;
}
pub fn northWest(b: Bitboard) Bitboard {
    return (b & ~file_a) << 7;
}
pub fn southEast(b: Bitboard) Bitboard {
    return (b & ~file_h) >> 7;
}
pub fn southWest(b: Bitboard) Bitboard {
    return (b & ~file_a) >> 9;
}

/// Lowest set square. Asserts a non-empty board.
pub fn lsb(b: Bitboard) Square {
    assert(b != 0);
    return @enumFromInt(@as(u6, @intCast(@ctz(b))));
}

/// Clears and returns the lowest set square — the movegen serialisation loop.
pub fn popLsb(b: *Bitboard) Square {
    const sq = lsb(b.*);
    b.* &= b.* - 1;
    return sq;
}

// --- squares and pieces ----------------------------------------------------------

pub const Square = enum(u6) {
    // zig fmt: off
    a1, b1, c1, d1, e1, f1, g1, h1,
    a2, b2, c2, d2, e2, f2, g2, h2,
    a3, b3, c3, d3, e3, f3, g3, h3,
    a4, b4, c4, d4, e4, f4, g4, h4,
    a5, b5, c5, d5, e5, f5, g5, h5,
    a6, b6, c6, d6, e6, f6, g6, h6,
    a7, b7, c7, d7, e7, f7, g7, h7,
    a8, b8, c8, d8, e8, f8, g8, h8,
    // zig fmt: on

    pub fn make(f: u3, r: u3) Square {
        return @enumFromInt((@as(u6, r) << 3) | f);
    }

    /// The inverse of `@tagName`: `"e4"` -> `.e4`, null if that is not the name
    /// of a square. Both the FEN en passant field and UCI move text are spelled
    /// this way, so the check lives in one place.
    pub fn fromName(text: []const u8) ?Square {
        if (text.len != 2) return null;
        if (text[0] < 'a' or text[0] > 'h') return null;
        if (text[1] < '1' or text[1] > '8') return null;
        return Square.make(@intCast(text[0] - 'a'), @intCast(text[1] - '1'));
    }

    pub fn file(sq: Square) u3 {
        return @truncate(@intFromEnum(sq));
    }

    pub fn rank(sq: Square) u3 {
        return @intCast(@intFromEnum(sq) >> 3);
    }

    pub fn bit(sq: Square) Bitboard {
        return @as(Bitboard, 1) << @intFromEnum(sq);
    }
};

pub const Color = enum(u1) {
    white,
    black,

    pub fn flip(c: Color) Color {
        return @enumFromInt(@intFromEnum(c) ^ 1);
    }
};

pub const PieceType = enum(u3) { pawn, knight, bishop, rook, queen, king };

/// Encoded `color << 3 | type`, so both halves are one mask away and the whole
/// thing is a single byte in the mailbox. 15 is the empty-square sentinel;
/// 6, 7 and 14 are unrepresentable.
pub const Piece = enum(u4) {
    // zig fmt: off
    w_pawn, w_knight, w_bishop, w_rook, w_queen, w_king,
    b_pawn = 8, b_knight, b_bishop, b_rook, b_queen, b_king,
    none = 15,
    // zig fmt: on

    pub fn make(c: Color, t: PieceType) Piece {
        return @enumFromInt((@as(u4, @intFromEnum(c)) << 3) | @intFromEnum(t));
    }

    pub fn color(p: Piece) Color {
        assert(p != .none);
        return @enumFromInt(@intFromEnum(p) >> 3);
    }

    pub fn pieceType(p: Piece) PieceType {
        assert(p != .none);
        return @enumFromInt(@as(u3, @truncate(@intFromEnum(p))));
    }
};

pub const CastlingRights = packed struct(u4) {
    white_kingside: bool = false,
    white_queenside: bool = false,
    black_kingside: bool = false,
    black_queenside: bool = false,

    pub const all: CastlingRights = .{
        .white_kingside = true,
        .white_queenside = true,
        .black_kingside = true,
        .black_queenside = true,
    };
};

// --- zobrist ----------------------------------------------------------------------
//
// origin: Albert Zobrist, "A New Hashing Method with Application for Game Playing",
//         Tech. Report #88, Computer Sciences Dept., University of Wisconsin-Madison, 1970
//         via https://www.chessprogramming.org/Zobrist_Hashing

const zobrist_seed: u64 = 0x6b6f_6a69_7a62; // "koji" + zb

const Zobrist = struct {
    /// Indexed straight by `@intFromEnum(Piece)`. The four unrepresentable codes
    /// get keys they will never be read with: 12 of 16 rows are live either way,
    /// so the dead rows cost no cache lines, only address space — and the direct
    /// index saves unpacking the piece back into color and type.
    piece: [16][64]u64,
    /// Applied when black is to move.
    side: u64,
    /// Indexed by the packed `CastlingRights`, so a rights change is
    /// `castling[old] ^ castling[new]` — two loads and no loop.
    castling: [16]u64,
    /// By file: the rank of an en passant target follows from the side to move.
    ep_file: [8]u64,
};

/// Generated at comptime from a fixed seed, so every build on every machine
/// agrees — the same requirement, and the same `SplitMix64` idiom, as the magic
/// search in `attacks.zig`.
pub const zobrist: Zobrist = blk: {
    @setEvalBranchQuota(20_000);
    var rng: std.Random.SplitMix64 = .init(zobrist_seed);
    var z: Zobrist = undefined;
    for (&z.piece) |*square_keys| {
        for (square_keys) |*k| k.* = rng.next();
    }
    z.side = rng.next();
    for (&z.castling) |*k| k.* = rng.next();
    for (&z.ep_file) |*k| k.* = rng.next();
    break :blk z;
};

// --- piece-square tables ----------------------------------------------------------
//
// Lives here and not in `eval.zig` because `put`/`remove`/`movePiece` maintain
// the running total, and `eval.zig` imports `movegen.zig` imports `move.zig`, so
// a table over there would close an import cycle. Moving it back is the edit
// this comment exists to stop.
//
// The values are koji's own, generated below rather than transcribed. Why, and
// what that rules out, is in CREDITS.md.
//
// origin: piece-square tables — Jack Good, "A Five Year Plan for Automatic
//         Chess", Machine Intelligence 2, Edinburgh University Press, 1968,
//         the earliest publication CPW identifies on piece-and-square values
//         via https://www.chessprogramming.org/Piece-Square_Tables
// origin: tapered evaluation — Hans Berliner, "On the Construction of Evaluation
//         Functions for Large Domains", IJCAI-79, Tokyo, pp. 53-55, section III
//         "Smoothness"
//         via https://bkgm.com/articles/Berliner/EvaluationFunctionsLargeDomains/
// origin: packing the two scores into one integer so a single add carries both —
//         unclear (common to many engines by ~2016; no source found credits an
//         inventor, and CPW's Score page does not describe the trick at all)
//         via https://minuskelvin.net/chesswiki/content/packed-eval.html

/// A midgame and an endgame score in one `i32`: `(mg << 16) + eg`, so one add
/// carries both halves. They are *not* independent — a negative `eg` borrows out
/// of the low half, and the `+ 0x8000` in `mgOf` is what repairs it. Tested, not
/// trusted: "packed scores survive the borrow" in eval.zig sweeps the range.
pub const PackedScore = i32;

pub fn pack(mg: i32, eg: i32) PackedScore {
    return (mg << 16) + eg;
}

pub fn mgOf(s: PackedScore) i32 {
    return (s + 0x8000) >> 16;
}

pub fn egOf(s: PackedScore) i32 {
    return @as(i16, @truncate(s));
}

/// Folded into `piece_square` by `squareScore` at comptime, so no run-time path
/// adds them: what is left here is a scale for tests to assert against. Safe to
/// fold only because move ordering does not read them — `see.zig` keeps its own
/// copy (see the note there) and MVV-LVA ranks by piece-type tier. **Order
/// captures by these and the ordering inherits positional noise**, which is the
/// one cost folding has.
pub const piece_value_mg: [6]i32 = .{ 100, 320, 330, 500, 900, 0 };
pub const piece_value_eg: [6]i32 = .{ 115, 300, 320, 540, 950, 0 };

// Board geometry the knobs below are scaled against. `axisDist` runs
// 7,5,3,1,1,3,5,7 across a rank or file, so `axisCentre` runs 0,2,4,6,6,4,2,0
// and `centrality` peaks at 12 on the four centre squares; `ring` is 0 on the
// rim and 3 on the central 2x2.
fn axisDist(x: i32) i32 {
    return @intCast(@abs(2 * x - 7));
}

fn axisCentre(x: i32) i32 {
    return 7 - axisDist(x);
}

fn centrality(f: i32, r: i32) i32 {
    return axisCentre(f) + axisCentre(r);
}

fn ring(f: i32, r: i32) i32 {
    return @min(@min(f, 7 - f), @min(r, 7 - r));
}

fn onLongDiagonal(f: i32, r: i32) bool {
    return f == r or f + r == 7;
}

// The knobs, and the chess each one claims. Keeping the claim next to the number
// is what makes a generated table auditable and a retune reviewable — an edit
// that contradicts the line above it is a bug, an edit that agrees is tuning.
// Every one of these is an SPSA knob for Phase 5.

// Pawns: advancing is worth more the nearer the promotion square, and far more
// once there is an endgame to escort it through. Central pawns fight for the
// centre and rook pawns mostly do not, and one still on d2/e2 has a bishop
// locked in behind it.
const pawn_advance_mg = 3;
const pawn_advance_eg = 11;
const pawn_centre_file_mg = 4;
const pawn_unmoved_centre_mg = -18;

// Knights are short-range, so their value is dominated by how much board they
// can reach: the strongest centrality term of any piece, a rim that is dim, and
// a bonus for the advanced-and-central squares a knight is actually posted on.
const knight_centre_mg = 5;
const knight_centre_eg = 4;
const knight_rim_mg = -14;
const knight_outpost_mg = 6;

// Bishops: mild centrality, and a bonus for the two long diagonals, which are
// the most reach a bishop can have.
const bishop_centre_mg = 3;
const bishop_centre_eg = 3;
const bishop_long_diagonal_mg = 12;
const bishop_rim_mg = -8;

// Rooks: the seventh cuts the king off and eats the pawn rank. The file term is
// a weak stand-in for openness, which a square alone cannot see, and the corner
// penalty is for being undeveloped behind an unmoved rook pawn.
const rook_seventh_mg = 22;
const rook_seventh_eg = 12;
const rook_centre_file_mg = 4;
const rook_corner_mg = -8;

// Queens: mild on purpose. A queen's placement is about tempo, which is
// invisible from a square, so a strong centrality term here only makes her
// wander; the sortie penalty is for coming out early and being chased.
const queen_centre_mg = 1;
const queen_centre_eg = 4;
const queen_early_sortie_mg = -9;

// Kings: walking up the board in the midgame is how games are lost, castling
// either wing is how they are not, and the central files are the ones that open
// first. In the endgame the king is a piece again and belongs in the middle —
// the one term that reverses sign between the phases, and the reason tapering
// earns its place rather than merely interpolating.
const king_rank_penalty_mg = -22;
const king_flank_shelter_mg = 14;
const king_centre_file_mg = -16;
const king_centre_eg = 6;

/// White's orientation, rank 0 being white's back rank.
fn squareScore(t: PieceType, f: i32, r: i32) PackedScore {
    var mg: i32 = 0;
    var eg: i32 = 0;
    switch (t) {
        .pawn => {
            // Unreachable for a pawn; left zero so a bug that puts one there
            // reads as a discontinuity rather than a plausible number.
            if (r == 0 or r == 7) return pack(0, 0);
            mg = pawn_advance_mg * (r - 1) + pawn_centre_file_mg * axisCentre(f);
            eg = @divTrunc(pawn_advance_eg * (r - 1) * (r - 1), 4);
            if (r == 1 and (f == 3 or f == 4)) mg += pawn_unmoved_centre_mg;
        },
        .knight => {
            mg = knight_centre_mg * (centrality(f, r) - 6);
            eg = knight_centre_eg * (centrality(f, r) - 6);
            if (ring(f, r) == 0) mg += knight_rim_mg;
            if (r >= 3 and r <= 5 and ring(f, r) >= 2) mg += knight_outpost_mg;
        },
        .bishop => {
            mg = bishop_centre_mg * (centrality(f, r) - 6);
            eg = bishop_centre_eg * (centrality(f, r) - 6);
            if (onLongDiagonal(f, r)) mg += bishop_long_diagonal_mg;
            if (ring(f, r) == 0) mg += bishop_rim_mg;
        },
        .rook => {
            mg = @divTrunc(rook_centre_file_mg * axisCentre(f), 2);
            if (r == 6) {
                mg += rook_seventh_mg;
                eg += rook_seventh_eg;
            }
            if (r == 0 and (f == 0 or f == 7)) mg += rook_corner_mg;
        },
        .queen => {
            mg = queen_centre_mg * (centrality(f, r) - 6);
            eg = queen_centre_eg * (centrality(f, r) - 6);
            if (r >= 2 and r <= 4) mg += queen_early_sortie_mg;
        },
        .king => {
            mg = king_rank_penalty_mg * @as(i32, @min(r, 3));
            eg = king_centre_eg * (centrality(f, r) - 6);
            if (r == 0 and (f == 1 or f == 2 or f == 6)) mg += king_flank_shelter_mg;
            if (f == 3 or f == 4) mg += king_centre_file_mg;
        },
    }
    const i = @intFromEnum(t);
    return pack(mg + piece_value_mg[i], eg + piece_value_eg[i]);
}

/// Indexed straight by `@intFromEnum(Piece)`, for the same reason `zobrist.piece`
/// is. **Black's rows are the negated, rank-flipped white ones** (`sq ^ 56`),
/// resolved at comptime — that is what lets `Board.psqt` be a plain
/// white-relative total no lookup has to reorient.
pub const piece_square: [16][64]PackedScore = blk: {
    @setEvalBranchQuota(20_000);
    var t: [16][64]PackedScore = @splat(@splat(0));
    for (0..6) |i| {
        const pt: PieceType = @enumFromInt(i);
        for (0..64) |sq| {
            const s = squareScore(pt, @intCast(sq & 7), @intCast(sq >> 3));
            t[@intFromEnum(Piece.make(.white, pt))][sq] = s;
            t[@intFromEnum(Piece.make(.black, pt))][sq ^ 56] = -s;
        }
    }
    break :blk t;
};

// --- board -----------------------------------------------------------------------

pub const Board = struct {
    /// One bitboard per piece type, both colors mixed; a colored set is one AND
    /// with `by_color`. 8 words total instead of 12 keeps the whole piece
    /// placement in 64 bytes.
    by_type: [6]Bitboard = @splat(0),
    by_color: [2]Bitboard = @splat(0),
    /// The redundant square-centric half — see the module doc.
    mailbox: [64]Piece = @splat(.none),

    side: Color = .white,
    castling: CastlingRights = .{},
    /// En passant target square, if the last move was a double pawn push.
    ep: ?Square = null,
    /// Halfmoves since the last capture or pawn move (fifty-move rule).
    halfmove: u8 = 0,
    fullmove: u16 = 1,
    /// Zobrist key of everything above except the clocks — those move every ply
    /// without changing what the position is worth, and hashing them would give
    /// the same position a different key at every depth.
    hash: u64 = 0,
    /// Running `piece_square` total over every piece on the board, **white-
    /// relative**, maintained by the same three primitives that maintain `hash`.
    /// `computePsqt` is the independent readout and `consistent()` checks they
    /// agree, so a Debug build asserts this on every made and unmade move.
    ///
    /// Unlike `hash` this needs no entry in `Undo`: it has no state half, only a
    /// placement half, and unmake's placements are the exact inverse of make's —
    /// so it unwinds to itself.
    psqt: PackedScore = 0,

    pub const startpos: Board = init: {
        var b: Board = .{ .castling = .all };
        const back: [8]PieceType = .{ .rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook };
        for (back, 0..) |t, f| {
            b.put(Square.make(f, 0), Piece.make(.white, t));
            b.put(Square.make(f, 1), .w_pawn);
            b.put(Square.make(f, 6), .b_pawn);
            b.put(Square.make(f, 7), Piece.make(.black, t));
        }
        b.hash ^= b.hashState();
        break :init b;
    };

    pub fn pieces(b: *const Board, c: Color, t: PieceType) Bitboard {
        return b.by_type[@intFromEnum(t)] & b.by_color[@intFromEnum(c)];
    }

    pub fn occupancy(b: *const Board) Bitboard {
        return b.by_color[0] | b.by_color[1];
    }

    pub fn pieceAt(b: *const Board, sq: Square) Piece {
        return b.mailbox[@intFromEnum(sq)];
    }

    /// Puts a piece on an empty square. Captures are `remove` then `put`.
    pub fn put(b: *Board, sq: Square, p: Piece) void {
        assert(p != .none);
        assert(b.mailbox[@intFromEnum(sq)] == .none);
        b.by_type[@intFromEnum(p.pieceType())] |= sq.bit();
        b.by_color[@intFromEnum(p.color())] |= sq.bit();
        b.mailbox[@intFromEnum(sq)] = p;
        b.hash ^= zobrist.piece[@intFromEnum(p)][@intFromEnum(sq)];
        b.psqt += piece_square[@intFromEnum(p)][@intFromEnum(sq)];
    }

    /// Clears an occupied square and returns what was on it.
    pub fn remove(b: *Board, sq: Square) Piece {
        const p = b.mailbox[@intFromEnum(sq)];
        assert(p != .none);
        b.by_type[@intFromEnum(p.pieceType())] &= ~sq.bit();
        b.by_color[@intFromEnum(p.color())] &= ~sq.bit();
        b.mailbox[@intFromEnum(sq)] = .none;
        b.hash ^= zobrist.piece[@intFromEnum(p)][@intFromEnum(sq)];
        b.psqt -= piece_square[@intFromEnum(p)][@intFromEnum(sq)];
        return p;
    }

    /// Slides a piece to an empty square: one XOR pair per bitboard rather than
    /// the AND-NOT and OR that `remove` then `put` would cost.
    pub fn movePiece(b: *Board, from: Square, to: Square) void {
        const p = b.mailbox[@intFromEnum(from)];
        assert(p != .none);
        assert(b.mailbox[@intFromEnum(to)] == .none);
        const mask = from.bit() | to.bit();
        b.by_type[@intFromEnum(p.pieceType())] ^= mask;
        b.by_color[@intFromEnum(p.color())] ^= mask;
        b.mailbox[@intFromEnum(from)] = .none;
        b.mailbox[@intFromEnum(to)] = p;
        b.hash ^= zobrist.piece[@intFromEnum(p)][@intFromEnum(from)] ^
            zobrist.piece[@intFromEnum(p)][@intFromEnum(to)];
        b.psqt += piece_square[@intFromEnum(p)][@intFromEnum(to)] -
            piece_square[@intFromEnum(p)][@intFromEnum(from)];
    }

    /// The non-placement half of the hash: side, castling rights, en passant.
    /// `put`, `remove` and `movePiece` maintain the placement half as they go,
    /// so a board assembled by placement alone is missing exactly this much.
    fn hashState(b: *const Board) u64 {
        var h = zobrist.castling[@as(u4, @bitCast(b.castling))];
        if (b.side == .black) h ^= zobrist.side;
        if (b.ep) |sq| h ^= zobrist.ep_file[sq.file()];
        return h;
    }

    /// Rebuilds the hash from scratch. This is the independent readout that
    /// make/unmake's incrementally maintained `hash` is checked against — the
    /// same role `sliderAttacksSlow` plays for the magic tables. Nothing on a
    /// hot path calls it.
    pub fn computeHash(b: *const Board) u64 {
        var h = b.hashState();
        for (b.mailbox, 0..) |p, i| {
            if (p == .none) continue;
            h ^= zobrist.piece[@intFromEnum(p)][i];
        }
        return h;
    }

    /// Rebuilds the piece-square total from scratch. The independent readout
    /// that the incrementally maintained `psqt` is checked against, exactly as
    /// `computeHash` serves `hash`. Nothing on a hot path calls it.
    pub fn computePsqt(b: *const Board) PackedScore {
        var s: PackedScore = 0;
        for (b.mailbox, 0..) |p, i| {
            if (p == .none) continue;
            s += piece_square[@intFromEnum(p)][i];
        }
        return s;
    }

    /// The representation invariant: the bitboards and the piece-square total
    /// are exactly what rebuilding them from the mailbox produces. Implies
    /// color/type disjointness. This is what make/unmake asserts in Debug
    /// builds — O(64), so only there.
    pub fn consistent(b: *const Board) bool {
        var by_type: [6]Bitboard = @splat(0);
        var by_color: [2]Bitboard = @splat(0);
        for (b.mailbox, 0..) |p, i| {
            if (p == .none) continue;
            const sq_bit = @as(Bitboard, 1) << @intCast(i);
            by_type[@intFromEnum(p.pieceType())] |= sq_bit;
            by_color[@intFromEnum(p.color())] |= sq_bit;
        }
        return std.mem.eql(Bitboard, &by_type, &b.by_type) and
            std.mem.eql(Bitboard, &by_color, &b.by_color) and
            b.psqt == b.computePsqt();
    }

    /// Debug dump, `{f}`-printable: ranks 8→1 with FEN piece letters, then a
    /// FEN-ish status line. For humans staring at a perft divergence.
    pub fn format(b: *const Board, w: *Io.Writer) Io.Writer.Error!void {
        for (0..8) |i| {
            const r: u3 = @intCast(7 - i);
            try w.print("{d} ", .{@as(u8, r) + 1});
            for (0..8) |f| {
                const p = b.pieceAt(Square.make(@intCast(f), r));
                try w.writeByte(' ');
                try w.writeByte(if (p == .none) '.' else pieceChar(p));
            }
            try w.writeByte('\n');
        }
        try w.writeAll("\n  ");
        for ("abcdefgh") |f| {
            try w.writeByte(' ');
            try w.writeByte(f);
        }
        try w.writeAll("\n");

        // The status line *is* the FEN tail, so it is the same code.
        try b.writeTail(w);
        try w.writeByte('\n');
    }

    // --- FEN ------------------------------------------------------------------
    //
    // origin: Forsyth-Edwards Notation — David Forsyth (19th c., the placement
    //         run-length notation); formalised for computer chess by Steven
    //         Edwards as part of the PGN standard, 1994
    //         via https://www.chessprogramming.org/Forsyth-Edwards_Notation
    // origin: EPD, and the optional-clock defaults this parser follows —
    //         John Stanback and Steven Edwards
    //         via https://www.chessprogramming.org/Extended_Position_Description

    /// Serialises to Forsyth-Edwards Notation, without a trailing newline.
    /// `fromFen` of this is the board it came from, for every position koji
    /// can reach — asserted over `testdata/perft.epd`.
    pub fn writeFen(b: *const Board, w: *Io.Writer) Io.Writer.Error!void {
        for (0..8) |i| {
            const r: u3 = @intCast(7 - i);
            var empty: u8 = 0;
            for (0..8) |f| {
                const p = b.pieceAt(Square.make(@intCast(f), r));
                if (p == .none) {
                    empty += 1;
                    continue;
                }
                if (empty != 0) {
                    try w.writeByte('0' + empty);
                    empty = 0;
                }
                try w.writeByte(pieceChar(p));
            }
            if (empty != 0) try w.writeByte('0' + empty);
            if (r != 0) try w.writeByte('/');
        }
        try w.writeByte(' ');
        try b.writeTail(w);
    }

    /// Everything after the placement: side, castling, en passant, clocks.
    /// Shared with `format` so the debug dump and the real FEN cannot disagree.
    fn writeTail(b: *const Board, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte(if (b.side == .white) 'w' else 'b');
        try w.writeByte(' ');
        if (@as(u4, @bitCast(b.castling)) == 0) {
            try w.writeByte('-');
        } else {
            if (b.castling.white_kingside) try w.writeByte('K');
            if (b.castling.white_queenside) try w.writeByte('Q');
            if (b.castling.black_kingside) try w.writeByte('k');
            if (b.castling.black_queenside) try w.writeByte('q');
        }
        try w.writeByte(' ');
        if (b.ep) |sq| try w.writeAll(@tagName(sq)) else try w.writeByte('-');
        try w.print(" {d} {d}", .{ b.halfmove, b.fullmove });
    }

    /// Parses Forsyth-Edwards Notation. Two deliberate tolerances, both so that
    /// an EPD record parses unchanged — the perft oracle and every published
    /// test suite are EPD, not FEN:
    ///
    ///  1. The clocks are read only when they are entirely digits. EPD replaces
    ///     them with `hmvc`/`fmvn` operations whose defaults are 0 and 1, so a
    ///     non-numeric field 5 means "operations start here", not an error.
    ///     (The operations themselves are not interpreted; nothing needs them
    ///     yet, and `hmvc` has never mattered to a perft or a test suite.)
    ///  2. Anything after the last field consumed is ignored, which is what lets
    ///     a raw `<fen> ;D1 20 ;D2 400` line be handed straight over.
    ///
    /// The cost of (2) lands on UCI `position fen <fen> moves ...` in Phase 2:
    /// that handler must cut the line at the `moves` token itself, because this
    /// parser will otherwise swallow the move list without complaint.
    pub fn fromFen(text: []const u8) FenError!Board {
        var b: Board = .{};
        var it = std.mem.tokenizeAny(u8, text, " \t");

        try parsePlacement(&b, it.next() orelse return error.MissingField);

        const side = it.next() orelse return error.MissingField;
        b.side = if (isByte(side, 'w'))
            .white
        else if (isByte(side, 'b'))
            .black
        else
            return error.InvalidSide;

        try parseCastling(&b, it.next() orelse return error.MissingField);
        // Needs `side`: the legal ep rank follows from whose turn it is.
        try parseEnPassant(&b, it.next() orelse return error.MissingField);

        if (nextIfNumeric(&it)) |halfmove| {
            b.halfmove = std.fmt.parseInt(u8, halfmove, 10) catch return error.InvalidNumber;
            if (nextIfNumeric(&it)) |fullmove| {
                b.fullmove = std.fmt.parseInt(u16, fullmove, 10) catch return error.InvalidNumber;
                if (b.fullmove == 0) return error.InvalidNumber;
            }
        }

        // Four checks past syntax, because movegen's preconditions are not
        // recoverable further in: it takes `lsb(pieces(c, .king))`, which
        // asserts a non-empty board — and asserts vanish in ReleaseFast. A pawn
        // on the back rank is the same kind of trap: no move out of it is
        // representable. All four are cheap here and unfixable at depth 20.
        for ([_]Color{ .white, .black }) |c| {
            if (@popCount(b.pieces(c, .king)) != 1) return error.InvalidPlacement;
        }
        if (b.by_type[@intFromEnum(PieceType.pawn)] & (rankMask(0) | rankMask(7)) != 0) {
            return error.InvalidPlacement;
        }

        // The third: movegen trusts a castling right to mean the king and rook
        // are still home, because `makeMove`'s rights mask guarantees it for
        // every position koji reaches itself. A hand-written record can still
        // claim a right no placement backs, and the castle generated from it
        // would move a rook that is not there. Rejected rather than quietly
        // cleared — a position silently different from the record it was read
        // from is worse than a complaint.
        const Backing = struct { held: bool, color: Color, king: Square, rook: Square };
        for ([_]Backing{
            .{ .held = b.castling.white_kingside, .color = .white, .king = .e1, .rook = .h1 },
            .{ .held = b.castling.white_queenside, .color = .white, .king = .e1, .rook = .a1 },
            .{ .held = b.castling.black_kingside, .color = .black, .king = .e8, .rook = .h8 },
            .{ .held = b.castling.black_queenside, .color = .black, .king = .e8, .rook = .a8 },
        }) |r| {
            if (!r.held) continue;
            if (b.pieceAt(r.king) != Piece.make(r.color, .king)) return error.InvalidCastling;
            if (b.pieceAt(r.rook) != Piece.make(r.color, .rook)) return error.InvalidCastling;
        }

        // The fourth: material a game can actually produce. `movegen.max_moves`
        // is derived from this check — without it a record can put two dozen
        // queens on the board and generate more moves than the move list holds,
        // which in a release build is a write past its end. A side promotes at
        // most its eight pawns, so every piece beyond the starting complement
        // spends one, and the pawns still on the board spend the rest.
        for ([_]Color{ .white, .black }) |c| {
            // Starts at the pawns and only grows, so nine pawns is caught by the
            // one test at the end.
            var spent = @popCount(b.pieces(c, .pawn));
            inline for ([_]struct { t: PieceType, base: u7 }{
                .{ .t = .queen, .base = 1 },
                .{ .t = .rook, .base = 2 },
                .{ .t = .bishop, .base = 2 },
                .{ .t = .knight, .base = 2 },
            }) |g| {
                const n = @popCount(b.pieces(c, g.t));
                if (n > g.base) spent += n - g.base;
            }
            if (spent > 8) return error.InvalidPlacement;
        }

        // `parsePlacement` hashed the pieces through `put`; the rest of the
        // record is only known now.
        b.hash ^= b.hashState();
        return b;
    }
};

pub const FenError = error{
    MissingField,
    InvalidPlacement,
    InvalidSide,
    InvalidCastling,
    InvalidEnPassant,
    InvalidNumber,
};

/// Indexed by `PieceType`; lowercased for black. The one place the letters live.
const piece_chars = "PNBRQK";

pub fn pieceChar(p: Piece) u8 {
    const upper = piece_chars[@intFromEnum(p.pieceType())];
    return if (p.color() == .black) std.ascii.toLower(upper) else upper;
}

pub fn pieceFromChar(ch: u8) ?Piece {
    const idx = std.mem.indexOfScalar(u8, piece_chars, std.ascii.toUpper(ch)) orelse return null;
    return Piece.make(if (std.ascii.isLower(ch)) .black else .white, @enumFromInt(idx));
}

fn isByte(field: []const u8, ch: u8) bool {
    return field.len == 1 and field[0] == ch;
}

/// Consumes the next token only if it is entirely ASCII digits. `parseInt` alone
/// is too permissive for a clock: it takes a leading `+` and maps `-0` to 0.
fn nextIfNumeric(it: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
    const tok = it.peek() orelse return null;
    for (tok) |ch| if (!std.ascii.isDigit(ch)) return null;
    return it.next();
}

/// Ranks run 8→1, files a→h within a rank; digits are runs of empty squares.
/// Non-maximal runs (`44` for `8`) are accepted — unambiguous, and output
/// re-canonicalises them.
fn parsePlacement(b: *Board, field: []const u8) FenError!void {
    var ranks = std.mem.splitScalar(u8, field, '/');
    for (0..8) |i| {
        const r: u3 = @intCast(7 - i);
        var f: u8 = 0;
        for (ranks.next() orelse return error.InvalidPlacement) |ch| {
            switch (ch) {
                '1'...'8' => f += ch - '0',
                else => {
                    // Guards the @intCast below as much as the rank width.
                    if (f >= 8) return error.InvalidPlacement;
                    const p = pieceFromChar(ch) orelse return error.InvalidPlacement;
                    b.put(Square.make(@intCast(f), r), p);
                    f += 1;
                },
            }
            if (f > 8) return error.InvalidPlacement;
        }
        if (f != 8) return error.InvalidPlacement;
    }
    if (ranks.next() != null) return error.InvalidPlacement;
}

/// Standard chess only. Shredder-FEN and X-FEN spell the rights as rook files
/// (`AHah`), and those are rejected rather than ignored: silently dropping them
/// yields a position that is subtly wrong instead of a complaint. Chess960 is on
/// no roadmap phase; when it lands, this is where it starts.
fn parseCastling(b: *Board, field: []const u8) FenError!void {
    if (isByte(field, '-')) return;
    var seen: u4 = 0;
    for (field) |ch| {
        const bit: u4 = switch (ch) {
            'K' => 1 << 0,
            'Q' => 1 << 1,
            'k' => 1 << 2,
            'q' => 1 << 3,
            else => return error.InvalidCastling,
        };
        if (seen & bit != 0) return error.InvalidCastling;
        seen |= bit;
    }
    b.castling = .{
        .white_kingside = seen & 1 << 0 != 0,
        .white_queenside = seen & 1 << 1 != 0,
        .black_kingside = seen & 1 << 2 != 0,
        .black_queenside = seen & 1 << 3 != 0,
    };
}

fn parseEnPassant(b: *Board, field: []const u8) FenError!void {
    if (isByte(field, '-')) return;
    const sq = Square.fromName(field) orelse return error.InvalidEnPassant;

    // The target is the square a double-pushed pawn skipped, so its rank is
    // fixed by whose turn it now is: white to move means black just pushed
    // (rank 6), black to move means white did (rank 3). FEN sets this whether
    // or not the capture is actually available, so it is not a legality check —
    // a square on any other rank is a malformed record.
    if (sq.rank() != @as(u3, if (b.side == .white) 5 else 2)) return error.InvalidEnPassant;
    b.ep = sq;
}

// The layout claims above are contracts, not hopes: piece placement is 64 bytes
// of bitboards plus a 64-byte mailbox.
comptime {
    assert(@sizeOf(Piece) == 1);
    assert(@sizeOf([64]Piece) == 64);
    assert(@sizeOf([6]Bitboard) + @sizeOf([2]Bitboard) == 64);
}

// --- tests -------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "square mapping is LERF" {
    try expectEqual(@as(u6, 0), @intFromEnum(Square.a1));
    try expectEqual(@as(u6, 7), @intFromEnum(Square.h1));
    try expectEqual(@as(u6, 28), @intFromEnum(Square.e4));
    try expectEqual(@as(u6, 63), @intFromEnum(Square.h8));

    for (0..64) |i| {
        const sq: Square = @enumFromInt(i);
        try expectEqual(sq, Square.make(sq.file(), sq.rank()));
    }
}

test "piece encoding round-trips color and type" {
    const types = [_]PieceType{ .pawn, .knight, .bishop, .rook, .queen, .king };
    for ([_]Color{ .white, .black }) |c| {
        for (types) |t| {
            const p = Piece.make(c, t);
            try expect(p != .none);
            try expectEqual(c, p.color());
            try expectEqual(t, p.pieceType());
        }
    }
    try expectEqual(Color.black, Color.white.flip());
    try expectEqual(Color.white, Color.black.flip());
}

test "directional shifts mask the wrapping edge" {
    try expectEqual(@as(Bitboard, 0), east(Square.h4.bit()));
    try expectEqual(@as(Bitboard, 0), west(Square.a4.bit()));
    try expectEqual(@as(Bitboard, 0), northEast(Square.h4.bit()));
    try expectEqual(@as(Bitboard, 0), southWest(Square.a4.bit()));
    try expectEqual(@as(Bitboard, 0), north(Square.e8.bit()));
    try expectEqual(@as(Bitboard, 0), south(Square.e1.bit()));

    try expectEqual(Square.f5.bit(), northEast(Square.e4.bit()));
    try expectEqual(Square.d3.bit(), southWest(Square.e4.bit()));
    try expectEqual(Square.d5.bit(), northWest(Square.e4.bit()));
    try expectEqual(Square.f3.bit(), southEast(Square.e4.bit()));
}

test "lsb and popLsb walk a bitboard a1-upward" {
    var b: Bitboard = Square.c3.bit() | Square.a1.bit() | Square.h8.bit();
    try expectEqual(Square.a1, popLsb(&b));
    try expectEqual(Square.c3, popLsb(&b));
    try expectEqual(Square.h8, popLsb(&b));
    try expectEqual(@as(Bitboard, 0), b);
}

test "startpos bitboards and mailbox agree" {
    try expect(Board.startpos.consistent());
}

test "startpos facts" {
    const b = Board.startpos;

    try expectEqual(@as(u64, 16), @popCount(b.by_type[@intFromEnum(PieceType.pawn)]));
    try expectEqual(@as(u64, 4), @popCount(b.by_type[@intFromEnum(PieceType.knight)]));
    try expectEqual(@as(u64, 4), @popCount(b.by_type[@intFromEnum(PieceType.bishop)]));
    try expectEqual(@as(u64, 4), @popCount(b.by_type[@intFromEnum(PieceType.rook)]));
    try expectEqual(@as(u64, 2), @popCount(b.by_type[@intFromEnum(PieceType.queen)]));
    try expectEqual(@as(u64, 2), @popCount(b.by_type[@intFromEnum(PieceType.king)]));

    try expectEqual(rankMask(0) | rankMask(1), b.by_color[@intFromEnum(Color.white)]);
    try expectEqual(rankMask(6) | rankMask(7), b.by_color[@intFromEnum(Color.black)]);
    try expectEqual(rankMask(0) | rankMask(1) | rankMask(6) | rankMask(7), b.occupancy());

    try expectEqual(Piece.w_king, b.pieceAt(.e1));
    try expectEqual(Piece.b_queen, b.pieceAt(.d8));
    try expectEqual(Piece.w_rook, b.pieceAt(.a1));
    try expectEqual(Piece.b_knight, b.pieceAt(.g8));
    try expectEqual(Piece.none, b.pieceAt(.e4));

    try expectEqual(Square.e1.bit(), b.pieces(.white, .king));
    try expectEqual(rankMask(6), b.pieces(.black, .pawn));

    try expectEqual(Color.white, b.side);
    try expectEqual(CastlingRights.all, b.castling);
    try expect(b.ep == null);
    try expectEqual(@as(u8, 0), b.halfmove);
    try expectEqual(@as(u16, 1), b.fullmove);
}

test "put and remove keep the representation consistent" {
    var b = Board.startpos;

    const p = b.remove(.e2);
    try expectEqual(Piece.w_pawn, p);
    try expectEqual(Piece.none, b.pieceAt(.e2));
    try expect(b.consistent());

    b.put(.e4, p);
    try expectEqual(Piece.w_pawn, b.pieceAt(.e4));
    try expect(b.consistent());

    // A deliberately desynced board must fail the invariant.
    b.by_color[0] ^= Square.a3.bit();
    try expect(!b.consistent());
}

test "movePiece slides a piece without disturbing anything else" {
    var b = Board.startpos;
    var expected = Board.startpos;

    b.movePiece(.b1, .c3);
    _ = expected.remove(.b1);
    expected.put(.c3, .w_knight);

    try expect(b.consistent());
    try expect(std.meta.eql(expected, b));
}

test "zobrist keys are distinct and non-zero" {
    // A duplicate key is silent: two different positions share a hash and the
    // transposition table starts returning another position's move. This is the
    // one place it is cheap to rule out.
    var keys: [16 * 64 + 1 + 16 + 8]u64 = undefined;
    var n: usize = 0;
    for (zobrist.piece) |square_keys| {
        for (square_keys) |k| {
            keys[n] = k;
            n += 1;
        }
    }
    keys[n] = zobrist.side;
    n += 1;
    for (zobrist.castling ++ zobrist.ep_file) |k| {
        keys[n] = k;
        n += 1;
    }
    try expectEqual(keys.len, n);

    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    for (keys, 0..) |k, i| {
        try expect(k != 0);
        if (i > 0) try expect(k != keys[i - 1]);
    }
}

test "the placement primitives maintain the hash" {
    var b = Board.startpos;
    try expectEqual(b.computeHash(), b.hash);

    const p = b.remove(.e2);
    try expectEqual(b.computeHash(), b.hash);
    b.put(.e4, p);
    try expectEqual(b.computeHash(), b.hash);
    b.movePiece(.e4, .e5);
    try expectEqual(b.computeHash(), b.hash);

    // Placement is only half of it: the state terms have to move the key too,
    // or every position would collide with its own mirror image.
    var same_placement = b;
    same_placement.side = .black;
    try expect(same_placement.computeHash() != b.computeHash());
    same_placement = b;
    same_placement.castling = .{};
    try expect(same_placement.computeHash() != b.computeHash());
    same_placement = b;
    same_placement.ep = .e6;
    try expect(same_placement.computeHash() != b.computeHash());

    // Clocks deliberately do not.
    same_placement = b;
    same_placement.halfmove +%= 1;
    same_placement.fullmove += 1;
    try expectEqual(b.computeHash(), same_placement.computeHash());
}

// --- FEN tests ---------------------------------------------------------------

const startpos_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

/// Serialises to a stack buffer. 91 bytes is the longest FEN this engine can
/// produce (71 placement + 20 tail), so 128 never truncates.
fn fenOf(b: *const Board, buf: []u8) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try b.writeFen(&w);
    return w.buffered();
}

fn expectRoundTrip(fen: []const u8) !void {
    const b = try Board.fromFen(fen);
    try expect(b.consistent());
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(fen, try fenOf(&b, &buf));
}

test "startpos round-trips through FEN in both directions" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(startpos_fen, try fenOf(&Board.startpos, &buf));
    try expect(std.meta.eql(Board.startpos, try Board.fromFen(startpos_fen)));
}

test "every position in testdata/perft.epd round-trips" {
    // The oracle file is the single source of these FENs — a copy in a test
    // array here would be free to drift from the one perft is checked against.
    var lines = std.mem.splitScalar(u8, @embedFile("perft_epd"), '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // The FEN is everything before the first perft operation.
        const cut = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        try expectRoundTrip(std.mem.trimEnd(u8, line[0..cut], " \t"));

        // The whole line, perft operations included, must parse identically:
        // that is what lets the `epd` command hand lines straight to the parser.
        try expect(std.meta.eql(
            try Board.fromFen(line[0..cut]),
            try Board.fromFen(line),
        ));
        seen += 1;
    }
    // Without this a renamed or empty embed would pass vacuously.
    try expectEqual(@as(usize, 6), seen);
}

test "en passant and castling subsets round-trip" {
    // No position in perft.epd carries an ep square, so the field would
    // otherwise only ever be exercised as '-'.
    try expectRoundTrip("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1");
    try expectRoundTrip("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3");

    for ([_][]const u8{ "-", "K", "Q", "k", "q", "kq", "KQ", "Kq", "KQkq" }) |rights| {
        var buf: [128]u8 = undefined;
        const fen = try std.fmt.bufPrint(
            &buf,
            "r3k2r/8/8/8/8/8/8/R3K2R w {s} - 0 1",
            .{rights},
        );
        try expectRoundTrip(fen);
    }
}

test "FEN tolerances: optional clocks, EPD operations, non-maximal runs" {
    // Four fields: EPD's hmvc/fmvn defaults.
    const short = try Board.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -");
    try expectEqual(@as(u8, 0), short.halfmove);
    try expectEqual(@as(u16, 1), short.fullmove);
    try expect(std.meta.eql(Board.startpos, short));

    // A strict EPD record puts operations, not digits, in field 5.
    const epd = try Board.fromFen(
        \\rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - bm e4; id "start";
    );
    try expect(std.meta.eql(Board.startpos, epd));

    // Non-maximal empty runs are unambiguous; output re-canonicalises them.
    var buf: [128]u8 = undefined;
    const loose = try Board.fromFen("rnbqkbnr/pppppppp/44/8/17/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    try std.testing.expectEqualStrings(startpos_fen, try fenOf(&loose, &buf));
}

test "malformed FEN is rejected with a specific error" {
    const cases = [_]struct { []const u8, FenError }{
        // Placement.
        .{ "rnbqkbnr/pppppppp/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "rnbqkbnrq/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "rnbqkbn/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "rnbqkbnr/pppppppp/08/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "xnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        // Structural: movegen's preconditions, not syntax.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNK w KQkq - 0 1", error.InvalidPlacement },
        .{ "rnbq1bnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        .{ "Pnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", error.InvalidPlacement },
        // Side to move.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1", error.InvalidSide },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR ww KQkq - 0 1", error.InvalidSide },
        // Castling, including the Shredder/X-FEN file letters koji does not accept.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkqX - 0 1", error.InvalidCastling },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w HAha - 0 1", error.InvalidCastling },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KK - 0 1", error.InvalidCastling },
        // Rights no placement backs: no rook on the corner, or no king at home.
        .{ "4k3/8/8/8/8/8/8/4K3 w K - 0 1", error.InvalidCastling },
        .{ "4k3/8/8/8/8/8/8/R3K3 w K - 0 1", error.InvalidCastling },
        .{ "4k3/8/8/8/8/8/8/R2K3R w Q - 0 1", error.InvalidCastling },
        .{ "r3k3/8/8/8/8/8/8/4K3 w k - 0 1", error.InvalidCastling },
        .{ "4k2r/8/8/8/8/8/8/4K3 w q - 0 1", error.InvalidCastling },
        // En passant, including a square on the wrong rank for the side to move.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e9 0 1", error.InvalidEnPassant },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq z6 0 1", error.InvalidEnPassant },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e 0 1", error.InvalidEnPassant },
        .{ "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e3 0 1", error.InvalidEnPassant },
        // Clocks.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 300 1", error.InvalidNumber },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0", error.InvalidNumber },
        // Truncated.
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR", error.MissingField },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w", error.MissingField },
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq", error.MissingField },
        .{ "", error.MissingField },
    };
    for (cases) |c| {
        try std.testing.expectError(c[1], Board.fromFen(c[0]));
    }
}

test "material no game can produce is rejected" {
    // The last two are the records that used to overflow `movegen.MoveList`:
    // 258 and 271 legal moves against a 256-entry array.
    for ([_][]const u8{
        "k7/Q7/QQQQQQQQ/Q7/RR6/BB6/NN6/K7 w - - 0 1", // ten queens: nine promotions
        "k7/P7/QQQQQQQQ/Q7/RR6/BB6/NN6/K7 w - - 0 1", // nine, but a pawn still owes one
        "k7/8/8/8/8/P7/PPPPPPPP/K7 w - - 0 1", // nine pawns
        "knQQQQQ1/nn5Q/QQ5Q/Q3Q2Q/Q6Q/Q6Q/Q5Q1/1QQQQQQK w - - 0 1",
        "BQQQQQQK/Q6Q/Q6Q/Q6Q/Q6Q/Q6Q/BR5Q/kBQQQQQQ w - - 0 1",
    }) |fen| {
        try std.testing.expectError(error.InvalidPlacement, Board.fromFen(fen));
    }

    // Accepted, so the check cannot pass by rejecting everything wide: the
    // ceiling itself — nine queens beside the starting pieces, eight promotions
    // exactly — a third rook, and a pawn spent on a second queen.
    for ([_][]const u8{
        "k7/8/QQQQQQQQ/Q7/RR6/BB6/NN6/K7 w - - 0 1",
        "k7/8/8/8/8/8/8/KRRR4 w - - 0 1",
        "4k3/8/8/8/8/8/PPPPPPP1/QQ2K3 w - - 0 1",
        startpos_fen,
    }) |fen| {
        _ = try Board.fromFen(fen);
    }
}

test "debug dump renders startpos" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Board.startpos.format(&w);
    const text = w.buffered();

    try expect(std.mem.indexOf(u8, text, "8  r n b q k b n r") != null);
    try expect(std.mem.indexOf(u8, text, "4  . . . . . . . .") != null);
    try expect(std.mem.indexOf(u8, text, "1  R N B Q K B N R") != null);
    try expect(std.mem.endsWith(u8, text, "w KQkq - 0 1\n"));
}
