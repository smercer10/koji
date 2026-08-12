//! koji — board representation.
//!
//! Hybrid: piece-centric bitboards for the set-wise operations movegen lives on,
//! plus a square-centric mailbox so "what sits on square x" is one byte load
//! instead of a probe over six type bitboards. The mailbox is redundant state;
//! everything that mutates it goes through `put`/`remove`, and `consistent()`
//! checks the agreement invariant so make/unmake can assert it in debug builds.
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

    pub const startpos: Board = init: {
        var b: Board = .{ .castling = .all };
        const back: [8]PieceType = .{ .rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook };
        for (back, 0..) |t, f| {
            b.put(Square.make(f, 0), Piece.make(.white, t));
            b.put(Square.make(f, 1), .w_pawn);
            b.put(Square.make(f, 6), .b_pawn);
            b.put(Square.make(f, 7), Piece.make(.black, t));
        }
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
    }

    /// Clears an occupied square and returns what was on it.
    pub fn remove(b: *Board, sq: Square) Piece {
        const p = b.mailbox[@intFromEnum(sq)];
        assert(p != .none);
        b.by_type[@intFromEnum(p.pieceType())] &= ~sq.bit();
        b.by_color[@intFromEnum(p.color())] &= ~sq.bit();
        b.mailbox[@intFromEnum(sq)] = .none;
        return p;
    }

    /// The representation invariant: the bitboards are exactly what rebuilding
    /// them from the mailbox produces. Implies color/type disjointness. This is
    /// what make/unmake asserts in debug builds once it exists.
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
            std.mem.eql(Bitboard, &by_color, &b.by_color);
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
                if (p == .none) {
                    try w.writeByte('.');
                } else {
                    const upper = "PNBRQK"[@intFromEnum(p.pieceType())];
                    try w.writeByte(if (p.color() == .black) std.ascii.toLower(upper) else upper);
                }
            }
            try w.writeByte('\n');
        }
        try w.writeAll("\n  ");
        for ("abcdefgh") |f| {
            try w.writeByte(' ');
            try w.writeByte(f);
        }
        try w.writeAll("\n");

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
        try w.print(" {d} {d}\n", .{ b.halfmove, b.fullmove });
    }
};

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
