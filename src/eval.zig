//! koji — static evaluation.
//!
//! Material and piece-square tables, interpolated between a midgame and an
//! endgame score by how much material is left on the board. Quiescence stands
//! between this and the search, so it is never asked about a position in the
//! middle of a capture sequence — but it still cannot see king safety, a passed
//! pawn or a piece with nowhere to go.
//!
//! The tables themselves live in `board.zig`, next to the Zobrist keys and for
//! the same reason: `put`/`remove`/`movePiece` maintain the running total, so
//! the table has to be reachable from where the maintenance happens. What is
//! left here is the interpretation — game phase, the interpolation, and the
//! side-to-move orientation negamax needs.
//!
//! **Every path here stays integer.** Not a style preference: `bench` must print
//! identical node counts on an AVX2 and a non-AVX2 build (CLAUDE.md), and float
//! accumulation reorders with SIMD width. That costs nothing today and is
//! load-bearing once NNUE inference is vectorised.

const std = @import("std");

const board = @import("board.zig");
const Board = board.Board;
const PieceType = board.PieceType;

/// Centipawns, from the perspective of the side to move. 32 bits rather than 16:
/// the mate range sits far above any material total, and the headroom means
/// nothing here has to think about overflow when scores are negated and summed.
pub const Score = i32;

/// Re-exported so the material scale reads from the module that owns the eval
/// rather than from the board. Folded into `board.piece_square` at comptime —
/// nothing adds them separately.
pub const piece_value_mg = board.piece_value_mg;
pub const piece_value_eg = board.piece_value_eg;

/// How strongly each piece type signals "there is still a midgame here".
/// Deliberately **not** the material values: these only have to describe how
/// fast the game empties out, and CPW records them as independently tunable.
/// Pawns count zero — a pawn ending is an endgame however many pawns are on.
//
// origin: this weighting and the 24-point total — unclear (folklore; the
//         formulation is the one CPW's Tapered Eval page presents, which
//         credits no author for the weights themselves)
//         via https://www.chessprogramming.org/Tapered_Eval
const phase_weight: [6]i32 = .{ 0, 1, 1, 2, 4, 0 };

/// Both sides at full material: 4 knights + 4 bishops + 8 rook-points +
/// 8 queen-points. High is the midgame, zero is a bare endgame.
pub const max_phase: i32 = 24;

/// Remaining material, as a number from `max_phase` down to 0.
///
/// Counts straight off the color-mixed type bitboards — the two colors are
/// summed anyway, so splitting them would be two popcounts for one number.
/// Recomputed rather than maintained: four popcounts is cheaper than another
/// incremental invariant to keep right across make/unmake.
pub fn phase(b: *const Board) i32 {
    var p: i32 = 0;
    inline for (1..5) |i| {
        p += phase_weight[i] * @as(i32, @popCount(b.by_type[i]));
    }
    // Promotions can put more material on than the game started with, which
    // would extrapolate past the midgame end of the scale. Clamp before
    // dividing, never after.
    return @min(p, max_phase);
}

/// Static score of `b`, **relative to the side to move**: positive is good for
/// whoever is about to play. Negamax requires that orientation — it negates a
/// child's score on the way up, which is only meaningful if the child scored
/// itself from its own mover's point of view.
pub fn evaluate(b: *const Board) Score {
    const p = phase(b);
    // `b.psqt` is white-relative and already carries material, so the whole
    // evaluation is this one interpolation.
    const score = @divTrunc(
        board.mgOf(b.psqt) * p + board.egOf(b.psqt) * (max_phase - p),
        max_phase,
    );
    // Interpolate first and negate second. `@divTrunc` rounds toward zero, so
    // doing it in this order keeps the two colors exactly symmetric — negating
    // a truncated value and truncating a negated one are not the same number.
    return if (b.side == .white) score else -score;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const movegen = @import("movegen.zig");

test "packed scores survive the borrow" {
    // The whole point of `+ 0x8000` in `mgOf`: a negative endgame half borrows
    // out of the midgame half, and every extraction has to undo that. Swept
    // rather than spot-checked, over a range far wider than real scores reach.
    var mg: i32 = -4000;
    while (mg <= 4000) : (mg += 7) {
        var eg: i32 = -4000;
        while (eg <= 4000) : (eg += 13) {
            const s = board.pack(mg, eg);
            try testing.expectEqual(mg, board.mgOf(s));
            try testing.expectEqual(eg, board.egOf(s));
        }
    }
}

test "packed scores add componentwise" {
    // What makes the accumulator legal: one `+=` has to move both halves, and
    // it has to keep working when either half crosses zero.
    const cases = [_][4]i32{
        .{ 120, -340, -45, 900 },
        .{ -1, -1, 1, 1 },
        .{ 0, -32, 0, 32 },
        .{ -900, 900, 900, -900 },
        .{ 2000, 2000, -3500, -3500 },
    };
    for (cases) |c| {
        const sum = board.pack(c[0], c[1]) + board.pack(c[2], c[3]);
        try testing.expectEqual(c[0] + c[2], board.mgOf(sum));
        try testing.expectEqual(c[1] + c[3], board.egOf(sum));
    }
}

test "the accumulator cannot overflow its halves" {
    // A comptime bound, not a runtime check: 32 pieces of the largest-magnitude
    // entry in the table must stay well inside an i16, or the packing silently
    // stops being componentwise.
    comptime {
        @setEvalBranchQuota(20_000);
        var worst_mg: i32 = 0;
        var worst_eg: i32 = 0;
        for (board.piece_square) |square_scores| {
            for (square_scores) |s| {
                worst_mg = @max(worst_mg, @abs(board.mgOf(s)));
                worst_eg = @max(worst_eg, @abs(board.egOf(s)));
            }
        }
        // 32 pieces is the most a legal position can hold.
        std.debug.assert(32 * worst_mg < 32767);
        std.debug.assert(32 * worst_eg < 32767);
    }
}

test "the start position is dead level" {
    // Both halves, not just the blended score: this is what asserts that black's
    // tables really are the exact negated mirror of white's. A blend of two
    // wrong halves can still come out zero.
    try testing.expectEqual(@as(Score, 0), evaluate(&Board.startpos));
    try testing.expectEqual(@as(i32, 0), board.mgOf(Board.startpos.psqt));
    try testing.expectEqual(@as(i32, 0), board.egOf(Board.startpos.psqt));
}

test "evaluation is side-to-move relative" {
    // The same position with only the side to move flipped must score exactly
    // negated. This is the property negamax depends on, so it is worth asserting
    // directly rather than inferring it from search results.
    var b = try movegen.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 w kq - 0 1");
    const white_view = evaluate(&b);

    b.side = .black;
    try testing.expectEqual(-white_view, evaluate(&b));

    // ...and white is down exactly the rook that is missing from h1, table entry
    // included. Read off the table rather than restated as a literal: the point
    // is that the piece is gone, not what the tuning currently says it is worth.
    const h1_rook = board.piece_square[@intFromEnum(board.Piece.w_rook)][@intFromEnum(board.Square.h1)];
    const p = phase(&b);
    try testing.expectEqual(
        @divTrunc(board.mgOf(h1_rook) * p + board.egOf(h1_rook) * (max_phase - p), max_phase),
        evaluate(&b),
    );
}

test "a mirrored position scores identically for the side to move" {
    // Vertical mirror with colours swapped: materially and positionally the same
    // game, so the side to move must see the same number. **This is the test
    // that catches a missing `sq ^ 56` or a dropped negation on black's tables**
    // — every source that describes PSQT from scratch names that as the bug.
    const pairs = [_][2][]const u8{
        // Pawns, where the rank flip is most visible.
        .{ "4k3/8/8/8/8/8/4PP2/4K3 w - - 0 1", "4k3/4pp2/8/8/8/8/8/4K3 b - - 0 1" },
        // No pawns and no castling rights, so the mirror is exact in every term.
        .{ "4k3/8/8/3N4/8/8/8/4K3 w - - 0 1", "4k3/8/8/8/3n4/8/8/4K3 b - - 0 1" },
        .{ "6k1/8/8/8/8/8/8/R5K1 w - - 0 1", "r5k1/8/8/8/8/8/8/6K1 b - - 0 1" },
        // An asymmetric middlegame, which the tidy constructions above cannot
        // stress: every piece type on a different file and rank at once.
        .{
            "r2q1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 1",
            "r3kb1r/ppp1q1pp/2n1bp2/3np3/8/2NP1NP1/PP2PPBP/R2Q1RK1 b kq - 0 1",
        },
    };
    for (pairs) |pair| {
        const white_up = try movegen.fromFen(pair[0]);
        const black_up = try movegen.fromFen(pair[1]);
        try testing.expectEqual(evaluate(&white_up), evaluate(&black_up));
    }
}

test "phase runs from a full board down to a bare one" {
    try testing.expectEqual(max_phase, phase(&Board.startpos));

    const bare = try movegen.fromFen("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    try testing.expectEqual(@as(i32, 0), phase(&bare));

    // Pawns do not count: a pawn ending is an endgame however many are left.
    const pawns = try movegen.fromFen("4k3/pppppppp/8/8/8/8/PPPPPPPP/4K3 w - - 0 1");
    try testing.expectEqual(@as(i32, 0), phase(&pawns));

    // Rooks and queens only, so the weights are being read and not the counts.
    const heavy = try movegen.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    try testing.expectEqual(@as(i32, 8), phase(&heavy));

    // Promotions can push the raw sum past the maximum. Clamped, not wrapped.
    // Nine black queens is the legal ceiling — the original plus all eight pawns
    // promoted — against a white side that has not touched anything, which comes
    // to a raw phase of 48.
    const many_queens = try movegen.fromFen("qqqqkqqq/qq6/8/8/8/8/PPPPPPPP/RNBQKBNR w KQ - 0 1");
    try testing.expectEqual(max_phase, phase(&many_queens));
}

test "the tables say what the chess says" {
    // Guards the generator against an edit that inverts a term. Every assertion
    // here is a fact about chess, not a tuning choice, so a failure is always a
    // bug and never a retune.
    const sq = board.Square;
    const table = board.piece_square;
    const knight = table[@intFromEnum(board.Piece.w_knight)];
    const king = table[@intFromEnum(board.Piece.w_king)];
    const pawn = table[@intFromEnum(board.Piece.w_pawn)];
    const rook = table[@intFromEnum(board.Piece.w_rook)];

    // A knight on the rim is dim.
    try testing.expect(board.mgOf(knight[@intFromEnum(sq.a1)]) <
        board.mgOf(knight[@intFromEnum(sq.e4)]));
    // A king hides in the midgame and comes out in the endgame. The same two
    // squares, opposite orders — which is the whole point of tapering.
    try testing.expect(board.mgOf(king[@intFromEnum(sq.e4)]) <
        board.mgOf(king[@intFromEnum(sq.g1)]));
    try testing.expect(board.egOf(king[@intFromEnum(sq.e4)]) >
        board.egOf(king[@intFromEnum(sq.g1)]));
    // A pawn is worth more the closer it is to promoting, and much more so once
    // the board is empty enough to escort it.
    try testing.expect(board.egOf(pawn[@intFromEnum(sq.e7)]) >
        board.egOf(pawn[@intFromEnum(sq.e2)]));
    try testing.expect(board.egOf(pawn[@intFromEnum(sq.e7)]) >
        board.mgOf(pawn[@intFromEnum(sq.e7)]));
    // A rook on the seventh.
    try testing.expect(board.mgOf(rook[@intFromEnum(sq.a7)]) >
        board.mgOf(rook[@intFromEnum(sq.a5)]));
    // An unmoved centre pawn is a locked-in bishop, so it is worth less than the
    // same pawn one square up.
    try testing.expect(board.mgOf(pawn[@intFromEnum(sq.e2)]) <
        board.mgOf(pawn[@intFromEnum(sq.e3)]));

    // Material ordering, which no square term is allowed to overturn.
    try testing.expect(piece_value_mg[@intFromEnum(PieceType.pawn)] <
        piece_value_mg[@intFromEnum(PieceType.knight)]);
    try testing.expect(piece_value_mg[@intFromEnum(PieceType.knight)] <=
        piece_value_mg[@intFromEnum(PieceType.bishop)]);
    try testing.expect(piece_value_mg[@intFromEnum(PieceType.bishop)] <
        piece_value_mg[@intFromEnum(PieceType.rook)]);
    try testing.expect(piece_value_mg[@intFromEnum(PieceType.rook)] <
        piece_value_mg[@intFromEnum(PieceType.queen)]);
    // The king is free in both phases: it is never absent, so a value on it
    // would add a constant to both sides and cancel.
    try testing.expectEqual(@as(i32, 0), piece_value_mg[@intFromEnum(PieceType.king)]);
    try testing.expectEqual(@as(i32, 0), piece_value_eg[@intFromEnum(PieceType.king)]);
    // Pawns and rooks gain as the board empties, minor pieces give a little back.
    try testing.expect(piece_value_eg[@intFromEnum(PieceType.pawn)] >
        piece_value_mg[@intFromEnum(PieceType.pawn)]);
    try testing.expect(piece_value_eg[@intFromEnum(PieceType.rook)] >
        piece_value_mg[@intFromEnum(PieceType.rook)]);
    try testing.expect(piece_value_eg[@intFromEnum(PieceType.knight)] <
        piece_value_mg[@intFromEnum(PieceType.knight)]);
}

test "the accumulator agrees with a rebuild" {
    // `consistent()` checks this on every move in a Debug build; this is the
    // static half, over positions that make/unmake never has to reach.
    const fens = [_][]const u8{
        "r2q1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "qqqqkqqq/qq6/8/8/8/8/PPPPPPPP/RNBQKBNR w KQ - 0 1",
        "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
    };
    for (fens) |fen| {
        const b = try movegen.fromFen(fen);
        try testing.expectEqual(b.computePsqt(), b.psqt);
    }
}
