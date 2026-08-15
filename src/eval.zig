//! koji — static evaluation.
//!
//! Material only, for now. This exists because alpha-beta needs a number at the
//! leaves, not because it is a good judge of a position. Quiescence now stands
//! between it and the search, so it is at least never asked about a position in
//! the middle of a capture sequence — but it still cannot see king safety, a
//! passed pawn or a piece with nowhere to go. PSQT and tapering are their own
//! roadmap boxes and are what make this function worth reading.
//!
//! **Every path here stays integer.** Not a style preference: `bench` must print
//! identical node counts on an AVX2 and a non-AVX2 build (CLAUDE.md), and float
//! accumulation reorders with SIMD width. That costs nothing today and is
//! load-bearing once NNUE inference is vectorised.

const std = @import("std");

const board = @import("board.zig");
const Board = board.Board;
const Color = board.Color;
const PieceType = board.PieceType;

/// Centipawns, from the perspective of the side to move. 32 bits rather than 16:
/// the mate range sits far above any material total, and the headroom means
/// nothing here has to think about overflow when scores are negated and summed.
pub const Score = i32;

/// Centipawn value per piece type, indexed by `PieceType`.
///
/// The king is 0 — it is never absent, so counting it adds a constant to both
/// sides and cancels. Indexing it out of range would be the alternative, and a
/// zero costs one multiply-add that the popcount loop is doing anyway.
//
// origin: the 1/3/3/5/9 relative scale — Claude Shannon, "Programming a
//         Computer for Playing Chess", 1949. CPW's table gives Shannon's own
//         row as 100/300/300/500/900.
//         via https://www.chessprogramming.org/Point_Value
// origin: this exact set, 100/320/330/500/900 — Tomasz Michniewski, 1995, as
//         part of his "Simplified Evaluation Function". Named rather than
//         called folklore because CPW's comparison table lists this row under
//         his name; the many other published sets there differ.
//         via https://www.chessprogramming.org/Simplified_Evaluation_Function
pub const piece_value: [6]Score = .{
    100, // pawn
    320, // knight
    330, // bishop
    500, // rook
    900, // queen
    0, // king
};

/// Static score of `b`, **relative to the side to move**: positive is good for
/// whoever is about to play. Negamax requires that orientation — it negates a
/// child's score on the way up, which is only meaningful if the child scored
/// itself from its own mover's point of view.
pub fn evaluate(b: *const Board) Score {
    var score: Score = 0;
    inline for (0..6) |i| {
        const t: PieceType = @enumFromInt(i);
        const white = @popCount(b.pieces(.white, t));
        const black = @popCount(b.pieces(.black, t));
        score += piece_value[i] * (@as(Score, white) - @as(Score, black));
    }
    // `score` is white-relative up to here.
    return if (b.side == .white) score else -score;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const movegen = @import("movegen.zig");

test "the start position is dead level" {
    try testing.expectEqual(@as(Score, 0), evaluate(&Board.startpos));
}

test "evaluation is side-to-move relative" {
    // The same position with only the side to move flipped must score exactly
    // negated. This is the property negamax depends on, so it is worth asserting
    // directly rather than inferring it from search results.
    var b = try movegen.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 w kq - 0 1");
    const white_view = evaluate(&b);

    b.side = .black;
    try testing.expectEqual(-white_view, evaluate(&b));

    // ...and the missing white rook is worth exactly a rook to the side to move.
    try testing.expectEqual(piece_value[@intFromEnum(PieceType.rook)], evaluate(&b));
}

test "a mirrored position scores identically for the side to move" {
    // Vertical mirror with colours swapped: materially the same game, so the
    // side to move must see the same number. Catches a colour index swapped in
    // the popcount loop, which the symmetric start position cannot.
    const white_up = try movegen.fromFen("4k3/8/8/8/8/8/4PP2/4K3 w - - 0 1");
    const black_up = try movegen.fromFen("4k3/4pp2/8/8/8/8/8/4K3 b - - 0 1");
    try testing.expectEqual(evaluate(&white_up), evaluate(&black_up));
    try testing.expectEqual(2 * piece_value[@intFromEnum(PieceType.pawn)], evaluate(&white_up));
}

test "piece values are ordered and the king is free" {
    // Guards the table against a transposed edit: every ordering here is a fact
    // about chess, not a tuning choice, so a swap is always a bug.
    try testing.expect(piece_value[@intFromEnum(PieceType.pawn)] <
        piece_value[@intFromEnum(PieceType.knight)]);
    try testing.expect(piece_value[@intFromEnum(PieceType.knight)] <=
        piece_value[@intFromEnum(PieceType.bishop)]);
    try testing.expect(piece_value[@intFromEnum(PieceType.bishop)] <
        piece_value[@intFromEnum(PieceType.rook)]);
    try testing.expect(piece_value[@intFromEnum(PieceType.rook)] <
        piece_value[@intFromEnum(PieceType.queen)]);
    try testing.expectEqual(@as(Score, 0), piece_value[@intFromEnum(PieceType.king)]);
}
