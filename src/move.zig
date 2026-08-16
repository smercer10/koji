//! koji — move encoding, make and unmake.
//!
//! A move is 16 bits and carries no board state, so what it means depends on the
//! position it is played in. Make/unmake owns that: it takes a pseudo-legal move
//! and the `Undo` it hands back, and it is exactly reversible — the board after
//! `unmakeMove` is byte-identical to the board before `makeMove`, hash included.
//! That reversibility is the whole point, and it is what the tests at the bottom
//! assert; the perft driver is what will prove the move *semantics*.
//!
//! This file mutates `Board` but is not part of it: keeping make/unmake here
//! rather than as methods leaves the import graph acyclic (board <- move <-
//! movegen), which matters once movegen and search both need `Move`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;

const board = @import("board.zig");
const Board = board.Board;
const CastlingRights = board.CastlingRights;
const Color = board.Color;
const Piece = board.Piece;
const PieceType = board.PieceType;
const Square = board.Square;
const zobrist = board.zobrist;

// --- encoding --------------------------------------------------------------------

/// From, to, and a nibble for what kind of move it is — 16 bits, which is what
/// keeps a move list a cache-friendly array and leaves room for a score beside
/// it in a 32-bit slot later.
//
// origin: 16-bit from-to-plus-flags encoding — unclear (folklore; CPW documents
//         the scheme and its flag table without attributing either)
//         via https://www.chessprogramming.org/Encoding_Moves
pub const Move = packed struct(u16) {
    from: Square,
    to: Square,
    kind: Kind,

    /// Bit 3 is promotion, bit 2 is capture, and for a promotion the low two
    /// bits select the piece — so `isCapture` and `isPromotion` are one mask
    /// each rather than a switch. Codes 6 and 7 are unrepresentable.
    pub const Kind = enum(u4) {
        // zig fmt: off
        quiet       = 0,
        double_push = 1,
        castle_king = 2,
        castle_queen= 3,
        capture     = 4,
        ep_capture  = 5,
        promo_knight         = promotion_bit | 0,
        promo_bishop         = promotion_bit | 1,
        promo_rook           = promotion_bit | 2,
        promo_queen          = promotion_bit | 3,
        promo_capture_knight = promotion_bit | capture_bit | 0,
        promo_capture_bishop = promotion_bit | capture_bit | 1,
        promo_capture_rook   = promotion_bit | capture_bit | 2,
        promo_capture_queen  = promotion_bit | capture_bit | 3,
        // zig fmt: on

        const capture_bit: u4 = 1 << 2;
        const promotion_bit: u4 = 1 << 3;

        pub fn isCapture(k: Kind) bool {
            return @intFromEnum(k) & capture_bit != 0;
        }

        pub fn isPromotion(k: Kind) bool {
            return @intFromEnum(k) & promotion_bit != 0;
        }

        /// A capture or a promotion — the moves killers and history both refuse,
        /// stated once so the two cannot come to disagree about what a quiet is.
        pub fn isNoisy(k: Kind) bool {
            return k.isCapture() or k.isPromotion();
        }

        /// The piece a promotion promotes to. Asserts `isPromotion`.
        pub fn promoted(k: Kind) PieceType {
            assert(k.isPromotion());
            // knight..queen are consecutive in `PieceType`, and the low two bits
            // of a promotion code index them in that same order.
            return @enumFromInt(@intFromEnum(PieceType.knight) + (@intFromEnum(k) & 3));
        }

        /// The inverse: the code that promotes to `t`. Asserts `t` is a piece a
        /// pawn can actually become.
        pub fn promotion(t: PieceType, capturing: bool) Kind {
            assert(t != .pawn and t != .king);
            const index: u4 = @intFromEnum(t) - @intFromEnum(PieceType.knight);
            return @enumFromInt(promotion_bit | index | if (capturing) capture_bit else 0);
        }
    };

    pub fn init(from: Square, to: Square, kind: Kind) Move {
        return .{ .from = from, .to = to, .kind = kind };
    }

    /// Whole-move equality. The `@bitCast` pair is the cheap way to compare all
    /// three fields at once, and it is spelled here rather than at each caller
    /// because the width is this type's business: written out at the call site
    /// it hard-codes "a Move is exactly 16 bits" everywhere it appears, and
    /// widening the encoding then breaks every one of them instead of this.
    pub fn eql(a: Move, b: Move) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }

    /// UCI long algebraic, `{f}`-printable: `e2e4`, `a7a8q`. Castling is spelled
    /// as the king's real from-to (`e1g1`), which is what UCI wants outside
    /// Chess960.
    pub fn format(m: Move, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(@tagName(m.from));
        try w.writeAll(@tagName(m.to));
        // UCI spells the promoted piece in lower case, which is exactly how the
        // shared piece-letter table spells a black piece.
        if (m.kind.isPromotion()) {
            try w.writeByte(board.pieceChar(Piece.make(.black, m.kind.promoted())));
        }
    }

    /// Parses UCI long algebraic *against the position it is played in*: the
    /// kind is not in the text, so `e5d6` is an en passant capture or a quiet
    /// move depending on the board. Null if the text is malformed or names an
    /// empty from-square.
    ///
    /// This does not check legality — a GUI only sends legal moves, and movegen
    /// is the authority everywhere else. The one ambiguity that leaves is a king
    /// moving two files, which is read as a castle because nothing else can
    /// produce it.
    pub fn fromUci(b: *const Board, text: []const u8) ?Move {
        if (text.len != 4 and text.len != 5) return null;
        const from = Square.fromName(text[0..2]) orelse return null;
        const to = Square.fromName(text[2..4]) orelse return null;

        const moving = b.pieceAt(from);
        if (moving == .none) return null;
        const captures = b.pieceAt(to) != .none;

        if (text.len == 5) {
            const p = board.pieceFromChar(std.ascii.toLower(text[4])) orelse return null;
            const t = p.pieceType();
            if (t == .pawn or t == .king) return null;
            return Move.init(from, to, Kind.promotion(t, captures));
        }

        const kind: Kind = switch (moving.pieceType()) {
            .pawn => if (b.ep == to)
                .ep_capture
            else if (@abs(@as(i8, from.rank()) - @as(i8, to.rank())) == 2)
                .double_push
            else
                quietOrCapture(captures),
            .king => switch (@as(i8, to.file()) - @as(i8, from.file())) {
                2 => .castle_king,
                -2 => .castle_queen,
                else => quietOrCapture(captures),
            },
            else => quietOrCapture(captures),
        };
        return Move.init(from, to, kind);
    }
};

fn quietOrCapture(captures: bool) Move.Kind {
    return if (captures) .capture else .quiet;
}

// --- make and unmake ---------------------------------------------------------------
//
// origin: undo record holding the state a move destroys — unclear (folklore; CPW
//         describes the stack, the per-ply array and the move-carried variants,
//         attributing none of them)
//         via https://www.chessprogramming.org/Unmake_Move

/// What a move destroys and the position after it cannot supply. The search
/// keeps one per ply.
pub const Undo = struct {
    /// Whatever stood on the destination square — `.none` for a quiet move, and
    /// also for an en passant capture, whose pawn is not on the destination.
    captured: Piece,
    castling: CastlingRights,
    ep: ?Square,
    halfmove: u8,
    /// Saved rather than decremented back: the increment saturates, so at the
    /// ceiling it is not reversible and a FEN may start there. Free — it lands
    /// in padding the struct already had.
    fullmove: u16,
    /// Restored wholesale rather than recomputed: the incremental path would
    /// have to re-derive the castling delta backwards for no gain.
    hash: u64,
};

/// Applies a pseudo-legal move. Legality — leaving your own king in check — is
/// movegen's job, not this function's.
pub fn makeMove(b: *Board, m: Move) Undo {
    const undo: Undo = .{
        .captured = b.pieceAt(m.to),
        .castling = b.castling,
        .ep = b.ep,
        .halfmove = b.halfmove,
        .fullmove = b.fullmove,
        .hash = b.hash,
    };

    const us = b.side;
    const moving = b.pieceAt(m.from);
    assert(moving != .none and moving.color() == us);

    // An en passant target lives for exactly one ply, so it goes before anything
    // else can set a new one.
    if (b.ep) |sq| b.hash ^= zobrist.ep_file[sq.file()];
    b.ep = null;

    // Saturating: a FEN can hand us a clock near the limit, and the counter only
    // ever matters against 100.
    b.halfmove +|= 1;

    switch (m.kind) {
        .quiet => b.movePiece(m.from, m.to),
        .double_push => {
            b.movePiece(m.from, m.to);
            // The skipped square sits exactly between the two, in either
            // direction. The sum needs the extra bit: two squares in the upper
            // half of the board overflow a u6 before the halving brings it back.
            const sum = @as(u7, @intFromEnum(m.from)) + @intFromEnum(m.to);
            const skipped: Square = @enumFromInt(sum / 2);
            b.ep = skipped;
            b.hash ^= zobrist.ep_file[skipped.file()];
        },
        .castle_king, .castle_queen => {
            const rook = rookSquares(m.kind, m.to);
            b.movePiece(m.from, m.to);
            b.movePiece(rook.from, rook.to);
        },
        .capture => {
            _ = b.remove(m.to);
            b.movePiece(m.from, m.to);
        },
        .ep_capture => {
            _ = b.remove(capturedPawnSquare(us, m.to));
            b.movePiece(m.from, m.to);
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        .promo_capture_knight,
        .promo_capture_bishop,
        .promo_capture_rook,
        .promo_capture_queen,
        => {
            if (m.kind.isCapture()) _ = b.remove(m.to);
            _ = b.remove(m.from);
            b.put(m.to, Piece.make(us, m.kind.promoted()));
        },
    }

    if (moving.pieceType() == .pawn or m.kind.isCapture()) b.halfmove = 0;

    // Rights are lost by moving the king, by moving a rook off its home square,
    // and by capturing a rook on its home square. Masking by both endpoints
    // covers all three without a branch.
    const rights: u4 = @bitCast(b.castling);
    const kept = rights & castling_mask[@intFromEnum(m.from)] & castling_mask[@intFromEnum(m.to)];
    b.castling = @bitCast(kept);
    b.hash ^= zobrist.castling[rights] ^ zobrist.castling[kept];

    b.side = us.flip();
    b.hash ^= zobrist.side;
    // Saturating for the same reason as the halfmove clock above: a FEN can hand
    // us a counter already at the limit.
    if (us == .black) b.fullmove +|= 1;

    // O(64), so it is a Debug-only invariant rather than a plain assert: the
    // test and test-slow steps build ReleaseSafe, where this would turn deep
    // perft into an overnight job.
    if (builtin.mode == .Debug) assert(b.consistent());
    return undo;
}

/// Exactly reverses `makeMove` given the move and the record it returned.
pub fn unmakeMove(b: *Board, m: Move, undo: Undo) void {
    // Side first: everything below is written from the point of view of the
    // player who made the move.
    const us = b.side.flip();
    b.side = us;

    switch (m.kind) {
        .quiet, .double_push => b.movePiece(m.to, m.from),
        .castle_king, .castle_queen => {
            const rook = rookSquares(m.kind, m.to);
            b.movePiece(rook.to, rook.from);
            b.movePiece(m.to, m.from);
        },
        .capture => {
            b.movePiece(m.to, m.from);
            b.put(m.to, undo.captured);
        },
        .ep_capture => {
            b.movePiece(m.to, m.from);
            b.put(capturedPawnSquare(us, m.to), Piece.make(us.flip(), .pawn));
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        .promo_capture_knight,
        .promo_capture_bishop,
        .promo_capture_rook,
        .promo_capture_queen,
        => {
            _ = b.remove(m.to);
            b.put(m.from, Piece.make(us, .pawn));
            if (m.kind.isCapture()) b.put(m.to, undo.captured);
        },
    }

    b.castling = undo.castling;
    b.ep = undo.ep;
    b.halfmove = undo.halfmove;
    b.fullmove = undo.fullmove;
    // The primitives above went on maintaining the placement keys as they
    // unwound; the saved key overwrites all of that. A handful of dead xors on a
    // value already in a register buys one code path instead of two.
    b.hash = undo.hash;

    if (builtin.mode == .Debug) assert(b.consistent());
}

/// Where the rook comes from and goes, given the king's destination. The same
/// arithmetic serves both colors: only the rank differs, and castling does not
/// change it.
fn rookSquares(kind: Move.Kind, king_to: Square) struct { from: Square, to: Square } {
    const to: u6 = @intFromEnum(king_to);
    return switch (kind) {
        // g-file king: rook h -> f. c-file king: rook a -> d.
        .castle_king => .{ .from = @enumFromInt(to + 1), .to = @enumFromInt(to - 1) },
        .castle_queen => .{ .from = @enumFromInt(to - 2), .to = @enumFromInt(to + 1) },
        else => unreachable,
    };
}

/// The pawn an en passant capture takes: not on the destination square but one
/// rank back from it, from the capturing side's point of view. Public because
/// movegen has to reason about the same square when it checks whether taking en
/// passant exposes its own king — one rule, one home.
pub fn capturedPawnSquare(us: Color, to: Square) Square {
    const sq = @intFromEnum(to);
    return @enumFromInt(if (us == .white) sq - 8 else sq + 8);
}

/// Rights that survive a move touching each square.
//
// origin: unclear (folklore; CPW's Castling Rights page states which moves clear
//         which rights, not this way of applying it)
//         via https://www.chessprogramming.org/Castling_Rights
const castling_mask: [64]u4 = blk: {
    const wk: u4 = @bitCast(CastlingRights{ .white_kingside = true });
    const wq: u4 = @bitCast(CastlingRights{ .white_queenside = true });
    const bk: u4 = @bitCast(CastlingRights{ .black_kingside = true });
    const bq: u4 = @bitCast(CastlingRights{ .black_queenside = true });

    var mask: [64]u4 = @splat(~@as(u4, 0));
    mask[@intFromEnum(Square.e1)] = ~(wk | wq);
    mask[@intFromEnum(Square.h1)] = ~wk;
    mask[@intFromEnum(Square.a1)] = ~wq;
    mask[@intFromEnum(Square.e8)] = ~(bk | bq);
    mask[@intFromEnum(Square.h8)] = ~bk;
    mask[@intFromEnum(Square.a8)] = ~bq;
    break :blk mask;
};

comptime {
    assert(@sizeOf(Move) == 2);
}

// --- tests -------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "move encoding round-trips, and the flag bits mean what the kind says" {
    for (std.enums.values(Move.Kind)) |kind| {
        // Restated independently of the bit layout the accessors rely on.
        const is_capture = switch (kind) {
            .capture,
            .ep_capture,
            .promo_capture_knight,
            .promo_capture_bishop,
            .promo_capture_rook,
            .promo_capture_queen,
            => true,
            else => false,
        };
        const promoted: ?PieceType = switch (kind) {
            .promo_knight, .promo_capture_knight => .knight,
            .promo_bishop, .promo_capture_bishop => .bishop,
            .promo_rook, .promo_capture_rook => .rook,
            .promo_queen, .promo_capture_queen => .queen,
            else => null,
        };

        try expectEqual(is_capture, kind.isCapture());
        try expectEqual(promoted != null, kind.isPromotion());
        if (promoted) |t| {
            try expectEqual(t, kind.promoted());
            try expectEqual(kind, Move.Kind.promotion(t, is_capture));
        }

        for (0..64) |from| {
            const m = Move.init(@enumFromInt(from), @enumFromInt(63 - from), kind);
            try expectEqual(@as(Square, @enumFromInt(from)), m.from);
            try expectEqual(@as(Square, @enumFromInt(63 - from)), m.to);
            try expectEqual(kind, m.kind);
        }
    }
}

test "moves print as UCI long algebraic" {
    var buf: [8]u8 = undefined;

    for ([_]struct { Move, []const u8 }{
        .{ Move.init(.e2, .e4, .double_push), "e2e4" },
        .{ Move.init(.e1, .g1, .castle_king), "e1g1" },
        .{ Move.init(.a7, .a8, .promo_queen), "a7a8q" },
        .{ Move.init(.b7, .a8, .promo_capture_knight), "b7a8n" },
        .{ Move.init(.h2, .g1, .promo_capture_rook), "h2g1r" },
        .{ Move.init(.c7, .c8, .promo_bishop), "c7c8b" },
    }) |case| {
        var w: Io.Writer = .fixed(&buf);
        try case[0].format(&w);
        try expectEqualStrings(case[1], w.buffered());
    }
}

test "fromUci reads the kind off the position" {
    // A pawn on e5 beside a black pawn that has just double-pushed to d5, a king
    // and rooks on their home squares, and a white pawn one step from promoting.
    const b = try Board.fromFen("r3k2r/6P1/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1");

    for ([_]struct { []const u8, Move.Kind }{
        .{ "a1a4", .quiet },
        .{ "e5e6", .quiet },
        .{ "a1a8", .capture },
        .{ "e5d6", .ep_capture },
        .{ "e1g1", .castle_king },
        .{ "e1c1", .castle_queen },
        .{ "g7g8q", .promo_queen },
        .{ "g7g8n", .promo_knight },
        .{ "g7h8r", .promo_capture_rook },
        .{ "g7h8Q", .promo_capture_queen }, // tolerated: the spec says lower case
    }) |case| {
        const m = Move.fromUci(&b, case[0]) orelse return error.TestUnexpectedResult;
        try expectEqual(case[1], m.kind);

        // Whatever it parsed has to print back as the text it came from.
        var buf: [8]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try m.format(&w);
        try expectEqualStrings(std.ascii.lowerString(&buf, case[0]), w.buffered());
    }

    // Two ranks in one move is a double push only when a pawn does it.
    try expectEqual(Move.Kind.quiet, Move.fromUci(&b, "a1a3").?.kind);

    for ([_][]const u8{
        "e2e", // too short
        "e2e4e4", // too long
        "e2e9", // off the board
        "i2i4",
        "e2e4", // nothing on e2
        "g7g8k", // not a promotion piece
        "g7g8p",
        "g7g8x",
    }) |text| {
        try expect(Move.fromUci(&b, text) == null);
    }
}

/// Every case is `make` from `fen`, expect `after`, then `unmake` and expect the
/// original board back byte for byte. The FENs are hand-derived: they are the
/// statement of what a move kind is *supposed* to do, and perft is what will
/// prove the claim at scale.
const Case = struct { fen: []const u8, uci: []const u8, after: []const u8 };

const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const rooks_fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";

const cases = [_]Case{
    // Quiet, and the halfmove clock ticking.
    .{
        .fen = start_fen,
        .uci = "b1c3",
        .after = "rnbqkbnr/pppppppp/8/8/8/2N5/PPPPPPPP/R1BQKBNR b KQkq - 1 1",
    },
    // Double push sets the target square; a pawn move resets the clock.
    .{
        .fen = start_fen,
        .uci = "e2e4",
        .after = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
    },
    // Black's move is the one that increments the full-move number.
    .{
        .fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
        .uci = "c7c5",
        .after = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
    },
    // Capture.
    .{
        .fen = "4k3/8/8/3p4/4P3/8/8/4K3 w - - 4 9",
        .uci = "e4d5",
        .after = "4k3/8/8/3P4/8/8/8/4K3 b - - 0 9",
    },
    // En passant: the pawn that comes off is not on the destination square.
    .{
        .fen = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 3",
        .uci = "e5d6",
        .after = "4k3/8/3P4/8/8/8/8/4K3 b - - 0 3",
    },
    // All four castles, each costing that side both rights.
    .{ .fen = rooks_fen, .uci = "e1g1", .after = "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1" },
    .{ .fen = rooks_fen, .uci = "e1c1", .after = "r3k2r/8/8/8/8/8/8/2KR3R b kq - 1 1" },
    .{
        .fen = "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
        .uci = "e8g8",
        .after = "r4rk1/8/8/8/8/8/8/R3K2R w KQ - 1 2",
    },
    .{
        .fen = "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
        .uci = "e8c8",
        .after = "2kr3r/8/8/8/8/8/8/R3K2R w KQ - 1 2",
    },
    // Every promotion piece.
    .{ .fen = "4k3/P7/8/8/8/8/8/4K3 w - - 0 1", .uci = "a7a8q", .after = "Q3k3/8/8/8/8/8/8/4K3 b - - 0 1" },
    .{ .fen = "4k3/P7/8/8/8/8/8/4K3 w - - 0 1", .uci = "a7a8r", .after = "R3k3/8/8/8/8/8/8/4K3 b - - 0 1" },
    .{ .fen = "4k3/P7/8/8/8/8/8/4K3 w - - 0 1", .uci = "a7a8b", .after = "B3k3/8/8/8/8/8/8/4K3 b - - 0 1" },
    .{ .fen = "4k3/P7/8/8/8/8/8/4K3 w - - 0 1", .uci = "a7a8n", .after = "N3k3/8/8/8/8/8/8/4K3 b - - 0 1" },
    // The same three from the other side: the color-dependent arithmetic in the
    // en passant square and the promoted piece is where a mirror bug would hide.
    .{
        .fen = "4k3/8/8/8/4pP2/8/8/4K3 b - f3 0 1",
        .uci = "e4f3",
        .after = "4k3/8/8/8/8/5p2/8/4K3 w - - 0 2",
    },
    .{
        .fen = "4k3/8/8/8/8/8/6p1/4K3 b - - 0 1",
        .uci = "g2g1n",
        .after = "4k3/8/8/8/8/8/8/4K1n1 w - - 0 2",
    },
    .{
        .fen = "4k3/8/8/8/8/8/6p1/4K2R b K - 0 1",
        .uci = "g2h1q",
        .after = "4k3/8/8/8/8/8/8/4K2q w - - 0 2",
    },
    // Capture-promotion, taking the rook that carried the castling right with it.
    .{
        .fen = "4k2r/6P1/8/8/8/8/8/4K3 w k - 0 1",
        .uci = "g7h8q",
        .after = "4k2Q/8/8/8/8/8/8/4K3 b - - 0 1",
    },
    // Rights: a rook leaving home costs one, the king leaving costs both, and a
    // rook captured on its home square costs its owner one.
    .{ .fen = rooks_fen, .uci = "h1h2", .after = "r3k2r/8/8/8/8/8/7R/R3K3 b Qkq - 1 1" },
    .{ .fen = rooks_fen, .uci = "a1a2", .after = "r3k2r/8/8/8/8/8/R7/4K2R b Kkq - 1 1" },
    .{ .fen = rooks_fen, .uci = "e1e2", .after = "r3k2r/8/8/8/8/8/4K3/R6R b kq - 1 1" },
    .{ .fen = rooks_fen, .uci = "a1a8", .after = "R3k2r/8/8/8/8/8/8/4K2R b Kk - 0 1" },
};

test "each move kind does what it says, and unmake gives the position back" {
    var buf: [128]u8 = undefined;

    for (cases) |case| {
        const before = try Board.fromFen(case.fen);
        var b = before;

        const m = Move.fromUci(&b, case.uci) orelse return error.TestUnexpectedResult;
        const undo = makeMove(&b, m);

        var w: Io.Writer = .fixed(&buf);
        try b.writeFen(&w);
        try expectEqualStrings(case.after, w.buffered());
        try expect(b.consistent());
        try expectEqual(b.computeHash(), b.hash);

        unmakeMove(&b, m, undo);
        try expect(b.consistent());
        try expect(std.meta.eql(before, b));
    }
}

/// Plays a line, checking the invariants at every ply, then unwinds it all the
/// way back. The table above pins down what each kind does on its own; this is
/// about composition — that undo records stack and nothing leaks across plies.
fn playLine(start: []const u8, line: []const []const u8, checkpoints: []const ?[]const u8) !void {
    const before = try Board.fromFen(start);
    var b = before;

    var moves: [64]Move = undefined;
    var undos: [64]Undo = undefined;
    var buf: [128]u8 = undefined;

    for (line, 0..) |uci, ply| {
        moves[ply] = Move.fromUci(&b, uci) orelse return error.TestUnexpectedResult;
        undos[ply] = makeMove(&b, moves[ply]);

        try expect(b.consistent());
        try expectEqual(b.computeHash(), b.hash);

        if (ply < checkpoints.len) if (checkpoints[ply]) |fen| {
            var w: Io.Writer = .fixed(&buf);
            try b.writeFen(&w);
            try expectEqualStrings(fen, w.buffered());
        };
    }

    var ply = line.len;
    while (ply > 0) {
        ply -= 1;
        unmakeMove(&b, moves[ply], undos[ply]);
        try expect(b.consistent());
        try expectEqual(b.computeHash(), b.hash);
    }
    try expect(std.meta.eql(before, b));
}

test "a game unwinds to the position it started from" {
    // 1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxc6 dxc6 5. O-O — captures both ways,
    // a castle, and two pieces leaving squares that carry castling rights.
    try playLine(
        start_fen,
        &.{ "e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5c6", "d7c6", "e1g1" },
        &.{
            null,                                                                null, null, null,
            "r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3", null, null, null,
            "r1bqkbnr/1pp2ppp/p1p5/4p3/4P3/5N2/PPPP1PPP/RNBQ1RK1 b kq - 1 5",
        },
    );

    // Promotion, then a double push answered by an en passant capture — the
    // three kinds the game above never reaches.
    try playLine(
        "8/1p2k2P/8/2P5/8/8/8/4K3 w - - 0 1",
        &.{ "h7h8q", "b7b5", "c5b6" },
        &.{ null, null, "7Q/4k3/1P6/8/8/8/8/4K3 b - - 0 2" },
    );
}

test "unmake restores rights that were never lost" {
    // The mask is applied on every move, so a move that touches neither a king
    // nor a rook home square has to leave all four rights alone.
    var b = try Board.fromFen(rooks_fen);
    const m = Move.fromUci(&b, "e1e2").?;
    const undo = makeMove(&b, m);
    try expectEqual(CastlingRights{ .black_kingside = true, .black_queenside = true }, b.castling);

    const rook_move = Move.fromUci(&b, "h8g8").?;
    const back = makeMove(&b, rook_move);
    try expectEqual(CastlingRights{ .black_queenside = true }, b.castling);
    unmakeMove(&b, rook_move, back);
    unmakeMove(&b, m, undo);
    try expectEqual(CastlingRights.all, b.castling);
}

test "the move counter saturates instead of wrapping, and unmake restores it" {
    // A FEN may hand us a counter at the ceiling. The increment is the only
    // arithmetic in `makeMove` a record can drive out of range, and it did:
    // `perft 2` on this position wrapped it to zero in a release build.
    var b = try Board.fromFen("4k3/8/8/8/8/8/8/4K3 b - - 0 65535");
    const m = Move.fromUci(&b, "e8e7").?;
    const undo = makeMove(&b, m);
    try expectEqual(@as(u16, 65535), b.fullmove);
    unmakeMove(&b, m, undo);
    try expectEqual(@as(u16, 65535), b.fullmove);

    // Below the ceiling it still counts, and only after black moves.
    var c = try Board.fromFen("4k3/8/8/8/8/8/8/4K3 w - - 0 7");
    const white = Move.fromUci(&c, "e1e2").?;
    const wu = makeMove(&c, white);
    try expectEqual(@as(u16, 7), c.fullmove);
    const black = Move.fromUci(&c, "e8e7").?;
    const bu = makeMove(&c, black);
    try expectEqual(@as(u16, 8), c.fullmove);
    unmakeMove(&c, black, bu);
    try expectEqual(@as(u16, 7), c.fullmove);
    unmakeMove(&c, white, wu);
    try expectEqual(@as(u16, 7), c.fullmove);
}

test "the undo record still fits in the padding it had" {
    // `fullmove` was added to it to make the saturating increment reversible.
    // If this ever grows, it is on the make/unmake path and wants a measurement.
    try expectEqual(@as(usize, 16), @sizeOf(Undo));
}
