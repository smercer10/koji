//! koji — static exchange evaluation.
//!
//! Resolves the capture sequence on one square: both sides recapture with their
//! cheapest piece and either may stop once continuing would cost them. It runs
//! over a local copy of the occupancy, so the real board is never touched.
//!
//! **The attacker set is geometric, not legal**, so an absolutely pinned
//! defender counts as a recapture it could not play. That is the published
//! trade and not a bug to fix: every consumer stays correct when SEE is wrong,
//! only slower.
//
// origin: the swap-off value — Donald Michie and John Maynard Smith, SOMA
//         (Swapping Off Material Analyser), c. 1961, described in Maynard Smith
//         & Michie, "Machines that Play Games", New Scientist, 1961. Resolving
//         one square's capture sequence to decide whether a piece is en prise
//         predates engines by a decade.
//         via https://www.chessprogramming.org/SOMA
// origin: this bitboard formulation — the least-valuable-attacker loop, re-adding
//         x-rayed sliders against a shrinking occupancy, and the gain-array
//         negamax backward pass — unclear (folklore; CPW's page presents the
//         algorithm and attributes it to no one)
//         via https://www.chessprogramming.org/SEE_-_The_Swap_Algorithm

const std = @import("std");
const assert = std.debug.assert;

const board = @import("board.zig");
const Bitboard = board.Bitboard;
const Board = board.Board;
const PieceType = board.PieceType;
const lsb = board.lsb;

const attacks = @import("attacks.zig");

const move = @import("move.zig");
const Move = move.Move;

const movegen = @import("movegen.zig");

const eval = @import("eval.zig");
const Score = eval.Score;

/// Centipawns per piece type, **deliberately not `eval.piece_value`.** An
/// exchange must resolve the same way everywhere in the tree, and eval's values
/// start moving once PSQT and tapering land — sharing them would let a tuning
/// branch silently redirect every ordering decision in the engine. Only the
/// order pawn < knight ≈ bishop < rook < queen matters here.
pub const piece_value: [6]Score = .{
    100, // pawn
    300, // knight
    300, // bishop
    500, // rook
    900, // queen
    king_value,
};

comptime {
    // The least-valuable-attacker loop in `value` walks `by_type` in `PieceType`
    // order and takes the first non-empty bitboard, so it finds the *cheapest*
    // attacker only while this array is non-decreasing in that order. Retuning
    // is invited above; transposing two entries redirects every SEE verdict in
    // the engine, and no test can catch that, because each expectation in this
    // file is written in terms of these same constants.
    var i: usize = 1;
    while (i <= @intFromEnum(PieceType.king)) : (i += 1) {
        if (piece_value[i] < piece_value[i - 1]) {
            @compileError("see.piece_value must be non-decreasing in PieceType order");
        }
    }
}

/// A sentinel, not a value: the king is never captured. It only has to beat a
/// queen, and the king guard in `value` is what holds that bound — see there.
const king_value: Score = 10_000;

/// Every piece on the board, which bounds the attackers of one square. Real
/// sequences reach five or six.
const max_swaps = 32;

/// The material `m` wins or loses, resolved as a capture sequence on `m.to`.
/// Positive is good for the side to move. Zero is an even trade.
///
/// **Captures only, and not promotions** — see `winning`.
pub fn value(b: *const Board, m: Move) Score {
    assert(m.kind.isCapture());
    assert(!m.kind.isPromotion());

    const to = m.to;
    const us = b.side;

    // The initiating piece has left `from` before anything can be revealed
    // behind it. En passant additionally clears the pawn it takes, which is
    // *not* on `to` — clearing `to` instead would unmask sliders along the wrong
    // rank and leave the ones along the victim's rank blocked.
    var occ = b.occupancy() ^ m.from.bit();
    const captured: Score = if (m.kind == .ep_capture) blk: {
        occ ^= move.capturedPawnSquare(us, to).bit();
        break :blk piece_value[@intFromEnum(PieceType.pawn)];
    } else piece_value[@intFromEnum(b.pieceAt(to).pieceType())];

    // Hoisted: the type bitboards never change, only which of their bits are
    // still standing in `occ`.
    const diag = b.by_type[@intFromEnum(PieceType.bishop)] | b.by_type[@intFromEnum(PieceType.queen)];
    const orth = b.by_type[@intFromEnum(PieceType.rook)] | b.by_type[@intFromEnum(PieceType.queen)];

    // `& occ` is what removes the pieces the lines above virtually lifted:
    // `attackersTo` reads the board's type bitboards, which still hold them.
    var attackers = movegen.attackersTo(b, to, occ) & occ;

    // `gain[d]` is what the side to move at ply `d` nets if the exchange stops
    // right after its capture. Slot 0 is the piece standing on `to` now.
    var gain: [max_swaps]Score = undefined;
    gain[0] = captured;
    var d: usize = 0;

    // The piece sitting on `to` — what the next capture wins. It starts as the
    // one that just moved there and becomes each recapturer in turn.
    var exposed = piece_value[@intFromEnum(b.pieceAt(m.from).pieceType())];
    var side = us.flip();

    while (true) {
        const mine = attackers & b.by_color[@intFromEnum(side)];
        if (mine == 0) break;

        // Least valuable attacker: `PieceType` is already ordered by value, so
        // the first non-empty type bitboard is the answer.
        var t: usize = 0;
        var picked: Bitboard = 0;
        while (t < 6) : (t += 1) {
            picked = mine & b.by_type[t];
            if (picked != 0) break;
        }
        assert(picked != 0); // `mine` is non-empty, so some type has to match

        // A king may only take when nothing can take it back; otherwise the
        // recapture walks into check and is not a move.
        //
        // **No test distinguishes this from deleting it, and it still may not be
        // deleted.** Without it the king plays anyway and the backward pass
        // declines the line because `king_value` swamps everything — the same
        // answer by arithmetic accident. Deleting it would stay green while
        // moving `king_value`'s requirement from "beats a queen" to "beats every
        // exchange stackable on one square", which nine queens break.
        if (t == @intFromEnum(PieceType.king) and
            attackers & b.by_color[@intFromEnum(side.flip())] != 0) break;

        d += 1;
        // `occ` starts at no more than 31 bits — the occupancy less the moving
        // piece, less the victim pawn again for en passant — and each iteration
        // clears exactly one, so `d` stops at 30. Two slots of margin, and both
        // changes contemplated below (pricing promotions inside the swap-off,
        // keeping the initiator in `occ`) spend some of it.
        assert(d < gain.len);
        gain[d] = exposed - gain[d - 1];
        exposed = piece_value[t];

        // Battery handling: emptying the recapturer's square exposes whatever
        // stood behind it. Only sliders can hide there — a knight does not
        // attack along a ray, a king stands too close — so two lookups cover it.
        //
        // **Every term is parenthesised because Zig gives `&` and `|` one
        // precedence level, left-associative** (langref, Precedence). Without
        // them this parses as `((attackers | bishop) & diag) | rook) & orth`,
        // which compiles, runs, and silently never finds the x-ray.
        occ ^= lsb(picked).bit();
        attackers = (attackers |
            (attacks.bishopAttacks(to, occ) & diag) |
            (attacks.rookAttacks(to, occ) & orth)) & occ;

        side = side.flip();
    }

    // Backward pass. At each ply the side to move takes the better of stopping
    // here and letting it run on, and gains alternate sign — which is exactly
    // what makes a losing exchange simply not happen rather than be scored.
    while (d > 0) : (d -= 1) {
        gain[d - 1] = -@max(-gain[d - 1], gain[d]);
    }
    return gain[0];
}

/// Whether `m` wins or holds material. Equal trades count as winning: grouping
/// them with the losers would put every recapture behind the quiet moves.
///
/// **Promotions never reach here** — the caller keeps them in the winning band.
/// Pricing one inside the exchange means giving the pawn a queen-minus-pawn
/// value so the terms cancel if it is taken straight back, and engine authors
/// are split on whether that is worth carrying. Promotions are rare and cheap
/// to search, so koji takes the simple side of an open question.
pub fn winning(b: *const Board, m: Move) bool {
    assert(m.kind.isCapture());
    assert(!m.kind.isPromotion());

    const victim: PieceType = if (m.kind == .ep_capture) .pawn else b.pieceAt(m.to).pieceType();
    const attacker = b.pieceAt(m.from).pieceType();

    // Taking something worth at least what you risk cannot lose material:
    // stopping after the recapture already banks `victim - attacker >= 0`, and
    // the backward pass always allows stopping. Exact, not an approximation —
    // it just answers without building the sequence.
    if (piece_value[@intFromEnum(victim)] >= piece_value[@intFromEnum(attacker)]) return true;

    return value(b, m) >= 0;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// The named move in `fen`, which must parse as a capture in it.
fn capture(fen: []const u8, uci: []const u8) !struct { b: Board, m: Move } {
    attacks.init(); // runtime-initialised globals; never inherit an earlier test's
    const b = try movegen.fromFen(fen);
    const m = Move.fromUci(&b, uci).?;
    try testing.expect(m.kind.isCapture());
    return .{ .b = b, .m = m };
}

fn expectValue(fen: []const u8, uci: []const u8, want: Score) !void {
    const c = try capture(fen, uci);
    const got = value(&c.b, c.m);
    if (got != want) {
        std.debug.print("see({s}) in {s}: want {d}, got {d}\n", .{ uci, fen, want, got });
        return error.TestExpectedEqual;
    }
}

const pawn = piece_value[@intFromEnum(PieceType.pawn)];
const knight = piece_value[@intFromEnum(PieceType.knight)];
const bishop = piece_value[@intFromEnum(PieceType.bishop)];
const rook = piece_value[@intFromEnum(PieceType.rook)];

test "an undefended piece is worth exactly itself" {
    try expectValue("4k3/8/8/3p4/8/8/8/3RK3 w - - 0 1", "d1d5", pawn);
    try expectValue("4k3/8/8/3q4/8/8/8/3RK3 w - - 0 1", "d1d5", piece_value[@intFromEnum(PieceType.queen)]);
}

test "a defended pawn costs the rook that takes it" {
    // Rxd5, cxd5. SEE reports the price; the callers act on the sign.
    try expectValue("4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1", "d1d5", pawn - rook);
}

test "the cheapest defender recaptures, not merely some defender" {
    // Nxd5, cxd5, Rxd5, Qxd5: black must spend the pawn before the queen.
    // Recapturing with the queen first scores this +300 instead.
    try expectValue("4k3/8/2p1q3/3n4/8/4N3/3R4/4K3 w - - 0 1", "e3d5", 0);
}

test "the mover's own square empties before the attackers are counted" {
    // Covers `occ ^ from`, not the x-ray re-add: the attacker set is built with
    // the initiating piece already gone, so a battery behind *it* needs nothing
    // more. Rd2xd5, cxd5, Rd1xd5, then the same without the second rook.
    try expectValue("4k3/8/2p5/3p4/8/8/3R4/3RK3 w - - 0 1", "d2d5", pawn - rook + pawn);
    try expectValue("4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1", "d1d5", pawn - rook);

    // The other ray: Qh1 behind Bg2 on the h1-d5 diagonal.
    try expectValue("4k3/8/2p5/3p4/8/8/6B1/4K2Q w - - 0 1", "g2d5", pawn - bishop + pawn);
}

test "a recapture reveals what was hiding behind it" {
    // The only test that reaches the x-ray re-add. Bb7 is blocked by its own
    // pawn on c6 and becomes an attacker only when that pawn recaptures:
    // Rd2xd5 +100, cxd5 -500, Rd1xd5 +100, Bxd5 -500 -> -400. Miss the reveal
    // and the bishop never answers, scoring this -300.
    try expectValue("4k3/1b6/2p5/3p4/8/8/3R4/3RK3 w - - 0 1", "d2d5", -(rook - pawn));
}

test "en passant clears the pawn it takes, not the square it lands on" {
    // The victim is on d5, the capture lands on d6. Rd1 is blocked by its own
    // pawn on d5 and reaches d6 only once it is gone, so clearing d6 instead
    // leaves the rook blocked and scores this a free pawn. Then the plain case.
    try expectValue("4k3/8/8/3pP3/8/K7/8/3r4 w - d6 0 1", "e5d6", 0);
    try expectValue("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6", pawn);
}

test "the king may not capture into a defence" {
    // Kxd5 is legal — d5 does not attack d4 — but c6 guards the square.
    const c = try capture("4k3/8/2p5/3p4/3K4/8/8/8 w - - 0 1", "d4d5");
    try testing.expect(value(&c.b, c.m) < 0);
    try testing.expect(!winning(&c.b, c.m));

    // With the defender gone the same capture is simply a free pawn.
    try expectValue("4k3/8/8/3p4/3K4/8/8/8 w - - 0 1", "d4d5", pawn);
}

test "the king sentinel only has to outrank a queen" {
    // The bound the king guard buys: the sentinel meets a single victim, never
    // a whole exchange. Read the guard's comment before trusting this — delete
    // the guard and this stays green while the real requirement grows.
    for (piece_value[0..@intFromEnum(PieceType.king)]) |v| {
        try testing.expect(king_value > v);
    }
}

test "a king that cannot recapture ends the sequence rather than joining it" {
    // Ra5xd5 takes a defended knight, a pawn answers, and White's only remaining
    // attacker is the king with a second black pawn still bearing on d5.
    try expectValue("4k3/8/2p1p3/R2n4/3K4/8/8/8 w - - 0 1", "a5d5", knight - rook);
}

/// Positions with dense, overlapping capture sets — where a wrong attacker
/// order, a missed x-ray or a sign slip in the backward pass has room to show.
const corpus = [_][]const u8{
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R b KQkq - 0 1",
    "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "2r3k1/1q1nbppp/r3p3/3pP3/pPpP4/P1Q2N2/2RN1PPP/2R4K b - b3 0 1",
    "4k3/8/2p5/3p4/8/8/3R4/3RK3 w - - 0 1",
};

/// Every capture the corpus generates, promotions excluded — SEE is not defined
/// for those here.
fn forEachCapture(comptime f: fn (*const Board, Move) anyerror!void) !usize {
    var seen: usize = 0;
    for (corpus) |fen| {
        attacks.init();
        const b = try movegen.fromFen(fen);

        var list: movegen.MoveList = undefined;
        movegen.generate(&b, &list);

        for (list.slice()) |m| {
            if (!m.kind.isCapture() or m.kind.isPromotion()) continue;
            seen += 1;
            try f(&b, m);
        }
    }
    return seen;
}

test "the winning shortcut agrees with the full exchange, everywhere" {
    // The shortcut is provable, but a provable shortcut still has to be typed
    // correctly, so the two paths are checked against each other.
    const checked = try forEachCapture(struct {
        fn f(b: *const Board, m: Move) !void {
            const exact = value(b, m);
            if (winning(b, m) != (exact >= 0)) {
                std.debug.print("shortcut disagrees on {f}: see {d}\n", .{ m, exact });
                return error.TestExpectedEqual;
            }
        }
    }.f);
    // A corpus that had stopped generating captures would pass this vacuously.
    try testing.expect(checked > 20);
}

test "no exchange wins more than its victim, or reaches the king sentinel" {
    // Upper bound: the defender may always decline to recapture. Lower: a score
    // anywhere near `king_value` means a king was captured and the guard leaks.
    _ = try forEachCapture(struct {
        fn f(b: *const Board, m: Move) !void {
            const victim: PieceType = if (m.kind == .ep_capture) .pawn else b.pieceAt(m.to).pieceType();
            const got = value(b, m);
            try testing.expect(got <= piece_value[@intFromEnum(victim)]);
            try testing.expect(@abs(got) < king_value);
        }
    }.f);
}
