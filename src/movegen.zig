//! koji — legal move generation.
//!
//! Every move this file produces is legal. Nothing is generated and then thrown
//! away: the position is measured first — who is checking the king, which squares
//! the opponent covers, which of our pieces are pinned — and those masks are
//! folded into each piece's destination set before a single `Move` is built. The
//! alternative, generating pseudo-legal moves and filtering them by making each
//! one, is what `generateSlow` in the tests below does, and it exists purely to
//! disagree with this file if this file is wrong.
//!
//! CPW presents both designs without declaring a winner, so "legal is faster" is
//! a hypothesis here, not a fact: the perft NPS in docs/testlog.md is the number
//! that will settle it if the filtering design is ever built for comparison.
//
// origin: legal generation from checker, evasion and pin masks — unclear
//         (folklore; converged on independently, and CPW's own description names
//         no inventor). The clearest published write-up of this exact shape is
//         Peter Ellis Jones, "Generating Legal Chess Moves Efficiently",
//         https://peterellisjones.com/posts/generating-legal-chess-moves-efficiently/,
//         which claims no invention either
//         via https://www.chessprogramming.org/Legal_Move

const std = @import("std");
const assert = std.debug.assert;

const attacks = @import("attacks.zig");
const board = @import("board.zig");
const Bitboard = board.Bitboard;
const Board = board.Board;
const Color = board.Color;
const Piece = board.Piece;
const PieceType = board.PieceType;
const Square = board.Square;
const lsb = board.lsb;
const popLsb = board.popLsb;

const move = @import("move.zig");
const Move = move.Move;

// --- move list ---------------------------------------------------------------------

/// Sized for what `Board.fromFen` accepts, not for the 218 legal moves of the
/// widest *reachable* position (a 1964 Petrović composition, proved maximal in
/// 2024). A FEN handed to `perft` or `epd` need not be reachable, and the 218
/// bounds nothing about one that is not — a hand-written 24-queen record used
/// to generate 271 moves and write past the end of this array.
///
/// `fromFen` now rejects material no game can produce, so the widest case left
/// is a king, nine queens (eight promotions) and the starting rooks, bishops
/// and knights. At each piece's mobility on an otherwise empty board that is
/// `8 + 2 + 9*27 + 2*14 + 2*13 + 2*8 = 323`, counting two castles for the king.
/// Spending a promotion on a pawn instead gives up 27 and returns at most 12,
/// so the maximum sits at zero pawns. 384 clears it with room to spare, and the
/// ceiling is loose anyway — those pieces block each other, and two independent
/// hill climbs over positions this parser accepts found nothing past 214.
//
// origin: the 218 figure — Nenad Petrović's position (1964), reported by Andrew
//         Shapira on CCC in 2005; proved maximal by Tobs40, 2024
//         via https://www.chessprogramming.org/Chess_Position
pub const max_moves = 384;

/// A fixed-size list, because the bound above is a fact and an allocator on this
/// path would not pay for itself. The search will want a score beside each move;
/// that is a 32-bit slot next to the 16-bit `Move`, and it can be added then.
///
/// **Declare one `undefined` and let `generate` initialise it.** `= .{}` looks
/// harmless — `moves` carries `undefined` as its own default — but it lowers to
/// a `memset` of the whole struct, which perft paid at every interior node:
/// 520 bytes a node before this array was widened, and 776 after. `generate`
/// sets `len` before anything reads it, so there is nothing to zero.
pub const MoveList = struct {
    moves: [max_moves]Move = undefined,
    len: usize = 0,

    pub fn add(l: *MoveList, m: Move) void {
        assert(l.len < max_moves);
        l.moves[l.len] = m;
        l.len += 1;
    }

    pub fn slice(l: *const MoveList) []const Move {
        return l.moves[0..l.len];
    }
};

// --- attack queries ------------------------------------------------------------------

/// Every piece of *either* color attacking `sq` under the given occupancy. The
/// occupancy is a parameter rather than `b.occupancy()` because the two callers
/// that matter both lie about it: the king danger sweep removes the king, and the
/// en passant test removes both pawns. Public — move ordering and SEE want it.
pub fn attackersTo(b: *const Board, sq: Square, occ: Bitboard) Bitboard {
    const i = @intFromEnum(sq);
    const queens = b.by_type[@intFromEnum(PieceType.queen)];
    // A pawn attacks `sq` exactly when it stands on a square that a pawn of the
    // *opposite* color on `sq` would attack — the relation reversed, which is
    // why the colors below look swapped.
    return (attacks.pawn_attacks[@intFromEnum(Color.white)][i] & b.pieces(.black, .pawn)) |
        (attacks.pawn_attacks[@intFromEnum(Color.black)][i] & b.pieces(.white, .pawn)) |
        (attacks.knight_attacks[i] & b.by_type[@intFromEnum(PieceType.knight)]) |
        (attacks.king_attacks[i] & b.by_type[@intFromEnum(PieceType.king)]) |
        (attacks.bishopAttacks(sq, occ) & (b.by_type[@intFromEnum(PieceType.bishop)] | queens)) |
        (attacks.rookAttacks(sq, occ) & (b.by_type[@intFromEnum(PieceType.rook)] | queens));
}

/// Every square `c` attacks under the given occupancy, defended pieces included —
/// an attack set covers occupied squares regardless of who stands there, which is
/// exactly what "the king may not go there" needs.
fn attackedBy(comptime c: Color, b: *const Board, occ: Bitboard) Bitboard {
    var set = attacks.pawnAttacksSet(c, b.pieces(c, .pawn));
    set |= attacks.king_attacks[@intFromEnum(lsb(b.pieces(c, .king)))];

    var knights = b.pieces(c, .knight);
    while (knights != 0) set |= attacks.knight_attacks[@intFromEnum(popLsb(&knights))];

    const queens = b.pieces(c, .queen);
    var diag = b.pieces(c, .bishop) | queens;
    while (diag != 0) set |= attacks.bishopAttacks(popLsb(&diag), occ);

    var orth = b.pieces(c, .rook) | queens;
    while (orth != 0) set |= attacks.rookAttacks(popLsb(&orth), occ);

    return set;
}

// --- position preconditions -----------------------------------------------------------

pub const IllegalPosition = error{IllegalPosition};

/// The preconditions `Board.fromFen` cannot check for itself. It already rejects
/// what it can see from placement alone — one king a side, no back-rank pawn, no
/// castling right without the king and rook to back it — but these two need
/// either attack detection or the en passant rule, and importing this file from
/// `board.zig` would invert the import graph.
///
/// Neither position below is reachable in a game; both are writable as a FEN, and
/// `koji perft <fen>` and `epd <file>` take FENs from outside the program. Both
/// are memory-unsafe rather than merely wrong, and only in release builds, where
/// the asserts that would catch them are gone:
///
///  1. **The side that just moved left its own king attacked.** Movegen would
///     generate a capture of that king, and the next `lsb(pieces(them, .king))`
///     is `@ctz(0)` — 64 into a `u6`. Two kings standing next to each other is
///     the same fault, since a king never appears in its own danger set.
///  2. **An en passant square with no double push behind it.** Movegen would
///     generate the capture, and `makeMove` calls `Board.remove` on an empty
///     square, whose `.none` piece type indexes `by_type[7]` — one word past a
///     `[6]Bitboard`, onto `by_color`.
pub fn legalPosition(b: *const Board) bool {
    const mover = b.side;
    const waiting = mover.flip();

    // The side to move may be in check; the side that just moved may not be.
    const their_king = lsb(b.pieces(waiting, .king));
    if (attackersTo(b, their_king, b.occupancy()) & b.by_color[@intFromEnum(mover)] != 0) {
        return false;
    }

    if (b.ep) |ep| {
        // `parseEnPassant` has already fixed the rank from the side to move, so
        // the two squares the double push must have used follow from the file.
        if (b.pieceAt(move.capturedPawnSquare(mover, ep)) != Piece.make(waiting, .pawn)) return false;
        if (b.pieceAt(ep) != .none) return false;
        if (b.pieceAt(Square.make(ep.file(), if (mover == .white) 6 else 1)) != .none) return false;
    }

    return true;
}

/// `Board.fromFen` plus `legalPosition`. Every path that takes a FEN from outside
/// the program goes through this; `Board.fromFen` on its own is for positions
/// already known to be sound, which is what the tests in `board.zig` use it for.
pub fn fromFen(text: []const u8) (board.FenError || IllegalPosition)!Board {
    const b = try Board.fromFen(text);
    if (!legalPosition(&b)) return error.IllegalPosition;
    return b;
}

// --- generation ----------------------------------------------------------------------

/// Everything a generator needs about the position, computed once per node.
const Ctx = struct {
    b: *const Board,
    occ: Bitboard,
    enemy: Bitboard,
    ksq: Square,
    /// Squares the opponent covers with our king lifted off the board.
    danger: Bitboard,
    /// Enemy pieces attacking our king — at most one, since double check returns
    /// before a `Ctx` is built.
    checkers: Bitboard,
    /// Where a non-king move may land: `~own`, or under single check the squares
    /// that block the checking ray plus the checker itself.
    target: Bitboard,
    /// Our pieces that may not leave the line through our own king.
    pinned: Bitboard,

    /// The line a piece on `from` is confined to, or all squares if it is free.
    fn pinMask(c: Ctx, from: Square) Bitboard {
        if (c.pinned & from.bit() == 0) return ~@as(Bitboard, 0);
        return attacks.line[@intFromEnum(c.ksq)][@intFromEnum(from)];
    }
};

/// Fills `list` with every legal move for the side to move.
pub fn generate(b: *const Board, list: *MoveList) void {
    list.len = 0;
    // Specialising on the side to move turns every pawn direction, rank mask and
    // castling square below into a comptime constant.
    switch (b.side) {
        inline else => |us| generateFor(us, b, list),
    }
}

fn generateFor(comptime us: Color, b: *const Board, list: *MoveList) void {
    const them = comptime us.flip();
    const own = b.by_color[@intFromEnum(us)];
    const enemy = b.by_color[@intFromEnum(them)];
    const occ = own | enemy;
    const ksq = lsb(b.pieces(us, .king));

    // The king is removed from the occupancy for this sweep, so a slider checking
    // it still covers the square behind it. Without that the king "hides behind
    // itself" and appears free to retreat straight down the checking ray.
    //
    // origin: king danger squares by lifting the king out of the occupancy —
    //         unclear (folklore; no CPW page states the removal rule, and no
    //         published source found claims it)
    //         via https://www.chessprogramming.org/Square_Attacked_By
    const danger = attackedBy(them, b, occ ^ ksq.bit());

    // King moves first, so that double check — where nothing else may move — is
    // just an early return rather than a special case.
    serialize(list, ksq, attacks.king_attacks[@intFromEnum(ksq)] & ~own & ~danger, enemy);

    const checkers = attackersTo(b, ksq, occ) & enemy;
    if (@popCount(checkers) > 1) return;

    const c: Ctx = .{
        .b = b,
        .occ = occ,
        .enemy = enemy,
        .ksq = ksq,
        .danger = danger,
        .checkers = checkers,
        .target = if (checkers != 0) blk: {
            // Block anywhere along the ray, or capture the checker. A knight or
            // pawn checker is never aligned with the king, so `between` is empty
            // for it and capture is all that is left — no branch needed.
            const chk = lsb(checkers);
            break :blk attacks.between[@intFromEnum(ksq)][@intFromEnum(chk)] | chk.bit();
        } else ~own,
        .pinned = pinnedPieces(us, b, ksq, occ, own),
    };

    generatePieces(us, c, list);
    generatePawns(us, c, list);
    if (checkers == 0) generateCastles(us, c, list);
}

/// Our pieces that stand alone between our king and an enemy slider.
//
// origin: absolute pins by x-ray sniper plus a single in-between blocker —
//         unclear (folklore; CPW describes the equivalent x-ray method and
//         credits no inventor)
//         via https://www.chessprogramming.org/Checks_and_Pinned_Pieces_(Bitboards)
fn pinnedPieces(
    comptime us: Color,
    b: *const Board,
    ksq: Square,
    occ: Bitboard,
    own: Bitboard,
) Bitboard {
    const them = comptime us.flip();
    const queens = b.pieces(them, .queen);
    // Snipers are found on an *empty* board on purpose: a slider that would hit
    // the king if nothing were in the way is precisely one that pins whatever is.
    var snipers = (attacks.bishopAttacks(ksq, 0) & (b.pieces(them, .bishop) | queens)) |
        (attacks.rookAttacks(ksq, 0) & (b.pieces(them, .rook) | queens));

    var pinned: Bitboard = 0;
    while (snipers != 0) {
        const s = popLsb(&snipers);
        const blockers = attacks.between[@intFromEnum(ksq)][@intFromEnum(s)] & occ;
        // Exactly one piece in the way, and it has to be ours to be pinned.
        if (blockers != 0 and blockers & (blockers -% 1) == 0) pinned |= blockers & own;
    }
    return pinned;
}

fn generatePieces(comptime us: Color, c: Ctx, list: *MoveList) void {
    const b = c.b;

    // A pinned knight can never move: no knight leap stays on a straight line.
    var knights = b.pieces(us, .knight) & ~c.pinned;
    while (knights != 0) {
        const from = popLsb(&knights);
        serialize(list, from, attacks.knight_attacks[@intFromEnum(from)] & c.target, c.enemy);
    }

    const queens = b.pieces(us, .queen);

    var diag = b.pieces(us, .bishop) | queens;
    while (diag != 0) {
        const from = popLsb(&diag);
        const to = attacks.bishopAttacks(from, c.occ) & c.target & c.pinMask(from);
        serialize(list, from, to, c.enemy);
    }

    var orth = b.pieces(us, .rook) | queens;
    while (orth != 0) {
        const from = popLsb(&orth);
        const to = attacks.rookAttacks(from, c.occ) & c.target & c.pinMask(from);
        serialize(list, from, to, c.enemy);
    }
}

/// Pawns move set-wise: one shift of the whole pawn set produces every push or
/// capture at once, and the origin square is recovered from the destination.
//
// origin: set-wise pawn pushes by parallel shift — unclear (folklore; CPW's page
//         is community-authored and credits no inventor)
//         via https://www.chessprogramming.org/Pawn_Pushes_(Bitboards)
fn generatePawns(comptime us: Color, c: Ctx, list: *MoveList) void {
    const white = us == .white;
    const up = if (white) board.north else board.south;
    const up_east = if (white) board.northEast else board.southEast;
    const up_west = if (white) board.northWest else board.southWest;
    // Deltas are the shift distances of those same functions, so `to - delta`
    // recovers the pawn that made the move.
    const d_up: i8 = if (white) 8 else -8;
    const d_east: i8 = if (white) 9 else -7;
    const d_west: i8 = if (white) 7 else -9;
    const double_rank = comptime board.rankMask(if (white) 3 else 4);
    const promo_rank = comptime board.rankMask(if (white) 7 else 0);

    const pawns = c.b.pieces(us, .pawn);
    const empty = ~c.occ;

    // The intermediate square of a double push only has to be *empty*; it is not
    // itself a destination, so the target mask is applied after it is used.
    const push1 = up(pawns) & empty;
    const push2 = up(push1) & empty & double_rank & c.target;

    addPawnMoves(c, list, push1 & c.target, d_up, .quiet, promo_rank);
    addPawnMoves(c, list, push2, 2 * d_up, .double_push, 0);
    addPawnMoves(c, list, up_east(pawns) & c.enemy & c.target, d_east, .capture, promo_rank);
    addPawnMoves(c, list, up_west(pawns) & c.enemy & c.target, d_west, .capture, promo_rank);

    if (c.b.ep) |ep| generateEnPassant(us, c, list, ep, pawns);
}

/// En passant deliberately ignores both `target` and `pinned`, and tests the
/// resulting occupancy directly instead. Two reasons, each on its own sufficient:
/// the capture takes a pawn that is not on the destination square, so it can
/// answer a check by a pawn whose square is not in `target`; and it vacates two
/// squares of the same rank at once, which can expose a rook or queen along that
/// rank even though neither pawn was pinned on its own.
///
/// The price of stepping around `target` is that this function owes the evasion
/// rule back in full, and the occupancy test alone does not pay it — that test
/// only sees sliders. The explicit checker test below covers the rest.
//
// origin: the horizontal en passant pin — unclear (folklore; CPW states the extra
//         test is required and names no discoverer). Position 3 of the perft
//         oracle in testdata/perft.epd is the case that exposes it
//         via https://www.chessprogramming.org/En_passant
fn generateEnPassant(comptime us: Color, c: Ctx, list: *MoveList, ep: Square, pawns: Bitboard) void {
    const them = comptime us.flip();
    const queens = c.b.pieces(them, .queen);
    const diag = c.b.pieces(them, .bishop) | queens;
    const orth = c.b.pieces(them, .rook) | queens;
    const captured = move.capturedPawnSquare(us, ep);

    // Bypassing `target` means the evasion rule has to be restated here, and it
    // is not the same rule. The capture removes exactly one enemy piece — the
    // pawn on `captured` — so any checker that is not that pawn is still giving
    // check afterwards, unless it is a slider whose ray the moving pawn happens
    // to block. Slider checks are therefore left to the occupancy test below,
    // which sees the block; a knight or a second pawn is unresolvable and rules
    // en passant out entirely.
    if (c.checkers & ~captured.bit() & ~(diag | orth) != 0) return;

    // Our pawns that can take on `ep` are the ones an enemy pawn standing on
    // `ep` would attack.
    var from_set = attacks.pawn_attacks[@intFromEnum(them)][@intFromEnum(ep)] & pawns;
    while (from_set != 0) {
        const from = popLsb(&from_set);
        const after = c.occ ^ from.bit() ^ ep.bit() ^ captured.bit();
        if (attacks.bishopAttacks(c.ksq, after) & diag != 0) continue;
        if (attacks.rookAttacks(c.ksq, after) & orth != 0) continue;
        list.add(Move.init(from, ep, .ep_capture));
    }
}

/// Castling needs the right, an empty path, and no attack on any square the king
/// occupies or crosses. Reusing the king danger set is exact here *because* the
/// caller only gets this far when the king is not in check: the only squares
/// whose danger the lifted king could distort are ones attacked through it, and
/// such an attack would be a check.
fn generateCastles(comptime us: Color, c: Ctx, list: *MoveList) void {
    const white = us == .white;
    const rights = c.b.castling;
    const home: Square = if (white) .e1 else .e8;

    // Queenside clears one more square than the king crosses: the b-file square
    // must be empty for the rook, but the king never steps on it.
    const king_side: struct { held: bool, empty: Bitboard, to: Square } = if (white)
        .{ .held = rights.white_kingside, .empty = Square.f1.bit() | Square.g1.bit(), .to = .g1 }
    else
        .{ .held = rights.black_kingside, .empty = Square.f8.bit() | Square.g8.bit(), .to = .g8 };
    const queen_side: struct { held: bool, empty: Bitboard, cross: Bitboard, to: Square } = if (white)
        .{
            .held = rights.white_queenside,
            .empty = Square.b1.bit() | Square.c1.bit() | Square.d1.bit(),
            .cross = Square.c1.bit() | Square.d1.bit(),
            .to = .c1,
        }
    else
        .{
            .held = rights.black_queenside,
            .empty = Square.b8.bit() | Square.c8.bit() | Square.d8.bit(),
            .cross = Square.c8.bit() | Square.d8.bit(),
            .to = .c8,
        };

    if (king_side.held and c.occ & king_side.empty == 0 and c.danger & king_side.empty == 0) {
        list.add(Move.init(home, king_side.to, .castle_king));
    }
    if (queen_side.held and c.occ & queen_side.empty == 0 and c.danger & queen_side.cross == 0) {
        list.add(Move.init(home, queen_side.to, .castle_queen));
    }
}

// --- serialisation --------------------------------------------------------------------

/// Turns a destination set for one piece into moves.
fn serialize(list: *MoveList, from: Square, to_set: Bitboard, enemy: Bitboard) void {
    var set = to_set;
    while (set != 0) {
        const to = popLsb(&set);
        list.add(Move.init(from, to, if (to.bit() & enemy != 0) .capture else .quiet));
    }
}

/// Turns a set-wise pawn destination set into moves, recovering each origin as
/// `to - delta`. A destination on `promo_rank` expands into four moves; passing 0
/// for that mask says the shift can never reach a back rank, which is true of a
/// double push and lets the whole branch fold away.
fn addPawnMoves(
    c: Ctx,
    list: *MoveList,
    to_set: Bitboard,
    comptime delta: i8,
    comptime kind: Move.Kind,
    comptime promo_rank: Bitboard,
) void {
    var set = to_set;
    while (set != 0) {
        const to = popLsb(&set);
        const from: Square = @enumFromInt(@as(i8, @intFromEnum(to)) - delta);

        // Pawns are generated as a set, so the pin mask cannot be folded into the
        // destinations the way it is for a piece; it is checked per move instead.
        // The common case is an empty `pinned`, which fails on the first test.
        if (c.pinned & from.bit() != 0 and c.pinMask(from) & to.bit() == 0) continue;

        if (promo_rank != 0 and to.bit() & promo_rank != 0) {
            // Queen first: it is the move worth searching, and move ordering will
            // thank the generator for not putting three losing underpromotions
            // in front of it.
            for ([_]PieceType{ .queen, .rook, .bishop, .knight }) |t| {
                list.add(Move.init(from, to, Move.Kind.promotion(t, comptime kind.isCapture())));
            }
        } else {
            list.add(Move.init(from, to, kind));
        }
    }
}

// --- tests ---------------------------------------------------------------------------

const Io = std.Io;
const CastlingRights = board.CastlingRights;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// --- the slow oracle -----------------------------------------------------------------
//
// Everything below shares nothing with the fast path but `sliderAttacksSlow`,
// which is itself the oracle the magic tables are checked against. No leaper
// table, no `between`, no `line`, no pin or evasion mask: a move is generated if
// the piece's definition allows the shape, and kept if playing it leaves our king
// unattacked. Slow enough to be useless in an engine and simple enough to be
// obviously right, which is the whole job — the same role `sliderAttacksSlow`
// plays for `attacks.zig`.

/// Is `sq` attacked by any piece of color `c`? A scan of all 64 squares against
/// the geometric definition of each piece.
fn attackedSlow(b: *const Board, sq: Square, c: Color) bool {
    const occ = b.occupancy();
    for (0..64) |i| {
        const from: Square = @enumFromInt(i);
        const p = b.pieceAt(from);
        if (p == .none or p.color() != c) continue;

        const df = @as(i8, from.file()) - @as(i8, sq.file());
        const dr = @as(i8, from.rank()) - @as(i8, sq.rank());
        const hits = switch (p.pieceType()) {
            // A pawn attacks the two squares diagonally ahead of it, so seen
            // from the target it stands one rank *behind*.
            .pawn => @abs(df) == 1 and dr == @as(i8, if (c == .white) -1 else 1),
            .knight => (@abs(df) == 1 and @abs(dr) == 2) or (@abs(df) == 2 and @abs(dr) == 1),
            .king => (df != 0 or dr != 0) and @abs(df) <= 1 and @abs(dr) <= 1,
            .bishop => attacks.sliderAttacksSlow(.bishop, from, occ) & sq.bit() != 0,
            .rook => attacks.sliderAttacksSlow(.rook, from, occ) & sq.bit() != 0,
            .queen => (attacks.sliderAttacksSlow(.bishop, from, occ) |
                attacks.sliderAttacksSlow(.rook, from, occ)) & sq.bit() != 0,
        };
        if (hits) return true;
    }
    return false;
}

const CastleSpec = struct {
    color: Color,
    mask: u4,
    from: Square,
    to: Square,
    kind: Move.Kind,
    /// Must be vacant — the queenside rook crosses one square the king does not.
    empty: []const Square,
    /// Must be unattacked: every square the king stands on or steps over.
    cross: []const Square,
};

const castle_specs = [_]CastleSpec{
    .{
        .color = .white,
        .mask = @bitCast(CastlingRights{ .white_kingside = true }),
        .from = .e1,
        .to = .g1,
        .kind = .castle_king,
        .empty = &.{ .f1, .g1 },
        .cross = &.{ .f1, .g1 },
    },
    .{
        .color = .white,
        .mask = @bitCast(CastlingRights{ .white_queenside = true }),
        .from = .e1,
        .to = .c1,
        .kind = .castle_queen,
        .empty = &.{ .b1, .c1, .d1 },
        .cross = &.{ .c1, .d1 },
    },
    .{
        .color = .black,
        .mask = @bitCast(CastlingRights{ .black_kingside = true }),
        .from = .e8,
        .to = .g8,
        .kind = .castle_king,
        .empty = &.{ .f8, .g8 },
        .cross = &.{ .f8, .g8 },
    },
    .{
        .color = .black,
        .mask = @bitCast(CastlingRights{ .black_queenside = true }),
        .from = .e8,
        .to = .c8,
        .kind = .castle_queen,
        .empty = &.{ .b8, .c8, .d8 },
        .cross = &.{ .c8, .d8 },
    },
};

/// Every move whose *shape* is legal for the piece, ignoring whether it leaves
/// our own king attacked. Castling is the exception: its two extra rules cannot
/// be seen by a test on the position after the move, so they are applied here.
fn pseudoLegalSlow(b: *const Board, list: *MoveList) void {
    const us = b.side;
    const them = us.flip();
    const occ = b.occupancy();
    const dir: i8 = if (us == .white) 1 else -1;
    const start_rank: u3 = if (us == .white) 1 else 6;
    const last_rank: u3 = if (us == .white) 7 else 0;

    for (0..64) |fi| {
        const from: Square = @enumFromInt(fi);
        const p = b.pieceAt(from);
        if (p == .none or p.color() != us) continue;

        for (0..64) |ti| {
            const to: Square = @enumFromInt(ti);
            if (fi == ti) continue;
            const dest = b.pieceAt(to);
            if (dest != .none and dest.color() == us) continue;

            const df = @as(i8, to.file()) - @as(i8, from.file());
            const dr = @as(i8, to.rank()) - @as(i8, from.rank());

            switch (p.pieceType()) {
                .pawn => {
                    const kind: ?Move.Kind = if (df == 0 and dr == dir and dest == .none)
                        .quiet
                    else if (df == 0 and dr == 2 * dir and from.rank() == start_rank and
                        dest == .none and
                        b.pieceAt(Square.make(from.file(), @intCast(@as(i8, from.rank()) + dir))) == .none)
                        .double_push
                    else if (@abs(df) == 1 and dr == dir and dest != .none)
                        .capture
                    else if (@abs(df) == 1 and dr == dir and b.ep != null and b.ep.? == to)
                        .ep_capture
                    else
                        null;

                    if (kind) |k| {
                        if (to.rank() == last_rank) {
                            for ([_]PieceType{ .knight, .bishop, .rook, .queen }) |t| {
                                list.add(Move.init(from, to, Move.Kind.promotion(t, k == .capture)));
                            }
                        } else {
                            list.add(Move.init(from, to, k));
                        }
                    }
                },
                .knight => if ((@abs(df) == 1 and @abs(dr) == 2) or (@abs(df) == 2 and @abs(dr) == 1)) {
                    list.add(Move.init(from, to, quietOrCapture(dest)));
                },
                // Castling is generated separately below, not as a king move.
                .king => if (@abs(df) <= 1 and @abs(dr) <= 1) {
                    list.add(Move.init(from, to, quietOrCapture(dest)));
                },
                .bishop => if (attacks.sliderAttacksSlow(.bishop, from, occ) & to.bit() != 0) {
                    list.add(Move.init(from, to, quietOrCapture(dest)));
                },
                .rook => if (attacks.sliderAttacksSlow(.rook, from, occ) & to.bit() != 0) {
                    list.add(Move.init(from, to, quietOrCapture(dest)));
                },
                .queen => if ((attacks.sliderAttacksSlow(.bishop, from, occ) |
                    attacks.sliderAttacksSlow(.rook, from, occ)) & to.bit() != 0)
                {
                    list.add(Move.init(from, to, quietOrCapture(dest)));
                },
            }
        }
    }

    for (castle_specs) |s| {
        if (s.color != us) continue;
        if (@as(u4, @bitCast(b.castling)) & s.mask == 0) continue;
        for (s.empty) |sq| {
            if (b.pieceAt(sq) != .none) break;
        } else {
            for (s.cross) |sq| {
                if (attackedSlow(b, sq, them)) break;
            } else {
                // The king's own square too: castling out of check is illegal.
                if (!attackedSlow(b, s.from, them)) list.add(Move.init(s.from, s.to, s.kind));
            }
        }
    }
}

fn quietOrCapture(dest: Piece) Move.Kind {
    return if (dest == .none) .quiet else .capture;
}

/// The oracle: generate every shape, play it, and keep it only if our own king
/// is not attacked in the position it produces.
fn generateSlow(b: *Board, list: *MoveList) void {
    list.len = 0;
    var pseudo: MoveList = .{};
    pseudoLegalSlow(b, &pseudo);

    const us = b.side;
    for (pseudo.slice()) |m| {
        const undo = move.makeMove(b, m);
        const ksq = lsb(b.pieces(us, .king));
        if (!attackedSlow(b, ksq, us.flip())) list.add(m);
        move.unmakeMove(b, m, undo);
    }
}

// --- comparison harness ----------------------------------------------------------------

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sorted, space-separated UCI text — the form move lists are compared in, so a
/// mismatch reads as a diff of two move lists rather than a count.
fn listText(list: *const MoveList, buf: []u8) ![]const u8 {
    var store: [max_moves][5]u8 = undefined;
    var items: [max_moves][]const u8 = undefined;
    for (list.slice(), 0..) |m, i| {
        var w: Io.Writer = .fixed(&store[i]);
        try m.format(&w);
        items[i] = w.buffered();
    }

    const sorted = items[0..list.len];
    std.mem.sort([]const u8, sorted, {}, strLess);

    var w: Io.Writer = .fixed(buf);
    for (sorted, 0..) |s, i| {
        if (i != 0) try w.writeByte(' ');
        try w.writeAll(s);
    }
    return w.buffered();
}

const text_buf_len = max_moves * 6;

fn expectSameMoves(oracle: *const MoveList, got: *const MoveList) !void {
    var a: [text_buf_len]u8 = undefined;
    var b: [text_buf_len]u8 = undefined;
    try expectEqualStrings(try listText(oracle, &a), try listText(got, &b));
}

/// Walks the whole tree below `b` to `depth`, checking the fast generator against
/// the oracle at every node on the way.
fn expectAgreesToDepth(b: *Board, depth: u8) !void {
    var fast: MoveList = .{};
    generate(b, &fast);

    var slow: MoveList = .{};
    generateSlow(b, &slow);
    expectSameMoves(&slow, &fast) catch |err| {
        std.debug.print("disagreement at:\n{f}\n", .{b});
        return err;
    };

    if (depth == 0) return;
    for (fast.slice()) |m| {
        const undo = move.makeMove(b, m);
        try expectAgreesToDepth(b, depth - 1);
        move.unmakeMove(b, m, undo);
    }
}

/// Every FEN in the perft oracle, which is also the set of positions the node
/// counts are checked against. Read from the file rather than copied, so the two
/// cannot drift apart.
fn oracleFens(buf: *[16][]const u8) []const []const u8 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, @embedFile("perft_epd"), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const cut = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        // Grow `buf` at the call sites rather than truncating here: a silently
        // dropped position is a test that quietly stops covering something.
        assert(n < buf.len);
        buf[n] = std.mem.trimEnd(u8, line[0..cut], " \t");
        n += 1;
    }
    return buf[0..n];
}

test "the fast generator agrees with the slow oracle across the perft positions" {
    attacks.init();
    var fens: [16][]const u8 = undefined;
    for (oracleFens(&fens)) |fen| {
        var b = try Board.fromFen(fen);
        try expectAgreesToDepth(&b, 2);
    }
}

test "the fast generator agrees with the slow oracle deep in a game" {
    // The perft positions above are middlegames; a walk reaches the endgames
    // where promotions, bare kings and stalemate live. Fixed seed, so a failure
    // reproduces exactly.
    attacks.init();
    var rng: std.Random.SplitMix64 = .init(0x6b6f_6a69);

    var fens: [16][]const u8 = undefined;
    for (oracleFens(&fens)) |fen| {
        for (0..8) |_| {
            var b = try Board.fromFen(fen);
            for (0..48) |_| {
                var fast: MoveList = .{};
                generate(&b, &fast);

                var slow: MoveList = .{};
                generateSlow(&b, &slow);
                expectSameMoves(&slow, &fast) catch |err| {
                    std.debug.print("disagreement at:\n{f}\n", .{b});
                    return err;
                };

                if (fast.len == 0) break; // checkmate or stalemate
                _ = move.makeMove(&b, fast.moves[rng.next() % fast.len]);
            }
        }
    }
}

// --- hand-written expectations -----------------------------------------------------
//
// Perft would catch every one of these, but only as a wrong number several plies
// deep. Each position below states in full what the rule is supposed to produce.

fn expectMoves(fen: []const u8, expected: []const []const u8) !void {
    attacks.init();
    var b = try Board.fromFen(fen);
    var got: MoveList = .{};
    generate(&b, &got);

    var want: MoveList = .{};
    for (expected) |uci| {
        want.add(Move.fromUci(&b, uci) orelse return error.TestUnexpectedResult);
    }
    try expectSameMoves(&want, &got);
}

test "the king may not retreat along the ray it is being checked on" {
    // Rook on e8, king on e4: e5 is obviously covered, and e3 — straight
    // backwards, the square the king's own body shadows — has to be covered too.
    try expectMoves("4r2k/8/8/8/4K3/8/8/8 w - - 0 1", &.{
        "e4d3", "e4d4", "e4d5", "e4f3", "e4f4", "e4f5",
    });
}

test "double check leaves only king moves, even when a checker could be taken" {
    // Rook e8 and knight d3 both check. The rook on d1 can capture the knight and
    // it makes no difference: one checker still stands.
    try expectMoves("4rk2/8/8/8/8/3n4/8/3RK3 w - - 0 1", &.{ "e1d2", "e1f1" });
}

test "a pin restricts a piece rather than freezing it" {
    // The rook on e4 is pinned by the rook on e8 and may still slide the length
    // of the pin, capture the pinner included — but never off the e-file.
    try expectMoves("4rk2/8/8/8/4R3/8/8/4K3 w - - 0 1", &.{
        "e4e2", "e4e3", "e4e5", "e4e6", "e4e7", "e4e8",
        "e1d1", "e1d2", "e1e2", "e1f1", "e1f2",
    });
}

test "a pinned pawn may take its pinner but not step off the pin" {
    // Bishop c3 pins the d2 pawn to e1. dxc3 stays on the pin line; d3 and d4
    // leave it.
    try expectMoves("4k3/8/8/8/8/2b5/3P4/4K3 w - - 0 1", &.{
        "d2c3", "e1d1", "e1e2", "e1f1", "e1f2",
    });
}

test "promotion resolves a check only by capturing the checker" {
    // d7d8 promotes but leaves the rook on e8 checking; dxe8 promotes and takes
    // it, in each of the four flavours.
    try expectMoves("4r2k/3P4/8/8/8/8/8/4K3 w - - 0 1", &.{
        "d7e8q", "d7e8r", "d7e8b", "d7e8n",
        "e1d1",  "e1d2",  "e1f1",  "e1f2",
    });
}

test "en passant is illegal when both pawns leaving the rank expose the king" {
    // King a5, pawn b5, black pawn c5, rook h5 — all on one rank. bxc6 e.p.
    // removes b5 and c5 at once and the rook sees the king. Neither pawn is
    // pinned on its own, so no ordinary pin test catches this.
    try expectMoves("8/8/8/KPp4r/8/8/8/7k w - c6 0 1", &.{
        "a5a4", "a5a6", "a5b6", "b5b6",
    });

    // The same position with the rook gone: the capture is legal, which is what
    // makes the case above a rule and not an accident.
    try expectMoves("8/8/8/KPp5/8/8/8/7k w - c6 0 1", &.{
        "a5a4", "a5a6", "a5b6", "b5b6", "b5c6",
    });

    // Mirrored, black to move: the arithmetic that finds the captured pawn and
    // the rank it vacates is colour-dependent, so both directions are asserted.
    try expectMoves("7K/8/8/8/kpP4R/8/8/8 b - c3 0 1", &.{
        "a4a3", "a4a5", "a4b3", "b4b3",
    });
}

test "en passant is illegal when it does not answer the check" {
    // A knight check cannot be resolved by an en passant capture at all: the
    // knight is not the piece coming off, and no pawn landing square blocks a
    // knight. Bypassing the evasion mask means this rule has to be restated in
    // `generateEnPassant`, and the first version of it did not.
    try expectMoves("4k3/8/8/3pP3/8/3n4/8/4K3 w - d6 0 1", &.{
        "e1d1", "e1d2", "e1e2", "e1f1",
    });

    // Same shape with a rook checking along rank 1: the capture neither blocks
    // it nor takes the checker, so it is still illegal — but that case is caught
    // by the occupancy test rather than by the rule above. The king has only the
    // three squares off the rank, since the rook covers all of it once the king
    // itself stops blocking.
    try expectMoves("4k3/8/8/3pP3/8/8/8/4K2r w - d6 0 1", &.{
        "e1d2", "e1e2", "e1f2",
    });
}

test "en passant answers a check by capturing the checking pawn" {
    // The pawn giving check stands on d5; the capture lands on d6. An evasion
    // mask built from the checker's square would reject the only pawn move that
    // actually resolves the check, which is why en passant bypasses that mask.
    try expectMoves("k7/8/8/3pP3/4K3/8/8/8 w - d6 0 1", &.{
        "e4d3", "e4d4", "e4d5", "e4e3", "e4f3", "e4f4", "e4f5", "e5d6",
    });
}

test "castling needs the right, a clear path, and safe squares to cross" {
    const cases = [_]struct { fen: []const u8, king: bool, queen: bool, note: []const u8 }{
        .{ .fen = "4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = true, .queen = true, .note = "clear" },
        .{ .fen = "4k3/8/8/8/8/8/8/R3K2R w - - 0 1", .king = false, .queen = false, .note = "no rights" },
        .{ .fen = "4k3/8/8/8/8/8/8/R3KB1R w KQ - 0 1", .king = false, .queen = true, .note = "f1 blocked" },
        .{ .fen = "4k3/8/8/8/8/8/8/RN2K2R w KQ - 0 1", .king = true, .queen = false, .note = "b1 blocked" },
        .{ .fen = "4rk2/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = false, .queen = false, .note = "in check" },
        .{ .fen = "5rk1/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = false, .queen = true, .note = "crosses f1" },
        .{ .fen = "4k1r1/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = false, .queen = true, .note = "lands on g1" },
        .{ .fen = "3rk3/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = true, .queen = false, .note = "crosses d1" },
        // b1 is attacked but the king never stands on it — only the rook passes
        // over, and a rook may pass through anything.
        .{ .fen = "1r2k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", .king = true, .queen = true, .note = "b1 attacked" },
        .{ .fen = "r3k2r/8/8/8/8/8/8/4K3 b kq - 0 1", .king = true, .queen = true, .note = "black, clear" },
    };

    attacks.init();
    for (cases) |c| {
        var b = try Board.fromFen(c.fen);
        var list: MoveList = .{};
        generate(&b, &list);

        var king = false;
        var queen = false;
        for (list.slice()) |m| switch (m.kind) {
            .castle_king => king = true,
            .castle_queen => queen = true,
            else => {},
        };
        expectEqual(c.king, king) catch |err| {
            std.debug.print("kingside, {s}: {s}\n", .{ c.note, c.fen });
            return err;
        };
        expectEqual(c.queen, queen) catch |err| {
            std.debug.print("queenside, {s}: {s}\n", .{ c.note, c.fen });
            return err;
        };
    }
}

test "positions movegen may not be handed are rejected at the parser" {
    attacks.init();
    for ([_][]const u8{
        // The side that just moved left its own king attacked — movegen would
        // generate a king capture, and the ply after that takes `lsb` of an
        // empty king board.
        "3k4/8/8/8/8/8/8/3RK3 w - - 0 1",
        "8/8/8/3kK3/8/8/8/8 w - - 0 1", // adjacent kings, the same fault
        "4k3/8/8/8/8/8/8/4K2r b - - 0 1", // black to move, white left in check
        // En passant squares no double push can have produced: nothing to
        // capture, the target occupied, or the pawn's origin still occupied.
        // `makeMove` would clear an empty square and index `by_type[7]`.
        "4k3/8/8/4P3/8/8/8/4K3 w - d6 0 1",
        "4k3/8/3n4/3pP3/8/8/8/4K3 w - d6 0 1",
        "4k3/3r4/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "4k3/8/8/8/3pP3/8/4B3/4K3 b - e3 0 1", // mirrored: origin e2 occupied
    }) |fen| {
        // `Board.fromFen` accepts them — the placement alone is well formed.
        _ = try Board.fromFen(fen);
        try std.testing.expectError(error.IllegalPosition, fromFen(fen));
    }

    // The legal neighbours of those, so the check cannot pass by rejecting
    // everything: an ordinary ep position, and a position where the side *to*
    // move is in check, which is fine.
    for ([_][]const u8{
        "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "4k3/8/8/8/3pP3/8/8/4K3 b - e3 0 1",
        "3k4/8/8/8/8/8/8/3RK3 b - - 0 1",
    }) |fen| {
        _ = try fromFen(fen);
    }
}

test "checkmate and stalemate generate nothing at all" {
    attacks.init();
    for ([_][]const u8{
        "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", // mate
        "7k/5Q2/8/8/8/8/8/K7 b - - 0 1", // stalemate: no legal move, not in check
    }) |fen| {
        var b = try Board.fromFen(fen);
        var list: MoveList = .{};
        generate(&b, &list);
        try expectEqual(@as(usize, 0), list.len);
    }
}

test "the move list holds the widest position there is" {
    attacks.init();
    // The standard maximum-mobility construction. Whatever it generates, the
    // oracle has to agree, and it has to fit — `max_moves` is a claim about the
    // bound, and this is the position that tests it.
    var b = try Board.fromFen("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNN1KB1 w - - 0 1");
    var fast: MoveList = .{};
    generate(&b, &fast);
    var slow: MoveList = .{};
    generateSlow(&b, &slow);

    try expectSameMoves(&slow, &fast);
    try expect(fast.len <= max_moves);
    try expectEqual(@as(usize, 218), fast.len);
}

test "startpos generates the twenty opening moves" {
    attacks.init();
    var b = Board.startpos;
    var list: MoveList = .{};
    generate(&b, &list);
    try expectEqual(@as(usize, 20), list.len);

    // Sixteen pawn moves and four knight moves, none of them captures.
    var pawns: usize = 0;
    for (list.slice()) |m| {
        if (b.pieceAt(m.from).pieceType() == .pawn) pawns += 1;
        try expect(!m.kind.isCapture());
    }
    try expectEqual(@as(usize, 16), pawns);
}
