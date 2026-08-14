//! koji — perft: the move generator's correctness oracle.
//!
//! Perft counts leaf nodes of the legal move tree to a fixed depth. That single
//! number is a remarkably sharp instrument: castling through check, the en
//! passant pin, promotion counting and undo leaks all change it, and they change
//! it deterministically, which no amount of game-playing does. When it disagrees,
//! `divide` splits the count by root move so the wrong branch can be chased down
//! one ply at a time.
//!
//! `testdata/perft.epd` is the reference. `zig build test` runs it under a node
//! budget so the turn gate stays fast; `zig build test-slow` runs every depth in
//! the file, and that is the run that has to be green before movegen work merges.
//
// origin: perft — disputed. CPW records R.C. Smith's COBOL RSCE-1 (c. 1978) as
//         the supposed first implementation, and Robert Hyatt's own claim to
//         have used the technique in the 1980s; the modern move-path-enumeration
//         formulation and the reference node counts are Steven Edwards', 1995
//         via https://www.chessprogramming.org/Perft
// origin: divide — unclear (folklore; CPW presents it as standard debugging
//         practice with no attributed author)
//         via https://www.chessprogramming.org/Perft
// origin: bulk counting (returning the move count at depth 1 instead of playing
//         the last ply) — unclear (folklore; CPW presents it as standard perft
//         practice and names no author)
//         via https://www.chessprogramming.org/Perft

const std = @import("std");
const Io = std.Io;

const board = @import("board.zig");
const Board = board.Board;

const move = @import("move.zig");
const Move = move.Move;

const movegen = @import("movegen.zig");
const MoveList = movegen.MoveList;

/// Leaf nodes below `b` at `depth`. `b` is restored exactly on return.
///
/// The last ply is counted rather than played: the number of legal moves at
/// depth 1 *is* the number of leaves below it, so making and unmaking each one
/// only to count 1 is work with no answer attached. This is standard, and it
/// changes no count — the moves it skips playing are still played whenever the
/// same position appears one ply higher in a deeper run.
pub fn perft(b: *Board, depth: u8) u64 {
    if (depth == 0) return 1;

    var list: MoveList = undefined;
    movegen.generate(b, &list);
    if (depth == 1) return list.len;

    var nodes: u64 = 0;
    for (list.slice()) |m| {
        const undo = move.makeMove(b, m);
        nodes += perft(b, depth - 1);
        move.unmakeMove(b, m, undo);
    }
    return nodes;
}

/// Perft split by root move: one `<uci> <nodes>` line each, then a blank line and
/// the total. Comparing two divides is how a wrong node count is localised.
pub fn divide(b: *Board, depth: u8, w: *Io.Writer) Io.Writer.Error!u64 {
    // No move is played at depth 0, so there is no root move to attribute the
    // one leaf to. It has to total 1 regardless: a divide that disagrees with
    // `perft` at the same depth is useless for the one job it has.
    if (depth == 0) {
        try w.print("\n1 nodes\n", .{});
        return 1;
    }

    var list: MoveList = undefined;
    movegen.generate(b, &list);

    var total: u64 = 0;
    for (list.slice()) |m| {
        const undo = move.makeMove(b, m);
        const nodes = perft(b, depth - 1);
        move.unmakeMove(b, m, undo);

        try w.print("{f} {d}\n", .{ m, nodes });
        total += nodes;
    }
    try w.print("\n{d} nodes\n", .{total});
    return total;
}

// --- EPD suite ----------------------------------------------------------------------

/// What a single perft in the suite is allowed to cost. Both caps are needed:
/// the node cap reads the count the *record* claims, so a mistyped `;D6 1` slips
/// under any budget and then runs a full depth-6 perft. Depth is what bounds the
/// work; expected nodes is what keeps the set of work identical on every machine.
pub const Limit = struct {
    nodes: u64,
    depth: u8,

    pub const unlimited: Limit = .{ .nodes = std.math.maxInt(u64), .depth = std.math.maxInt(u8) };
};

pub const Result = struct {
    /// Records whose FEN parsed; one that does not is counted in `failed`.
    positions: usize = 0,
    /// Well-formed `;D<n> <nodes>` operations seen. **`ran + skipped` must equal
    /// this**, which is what stops an operation from disappearing silently and
    /// the suite from reporting success having checked nothing.
    ops: usize = 0,
    /// Run, including those that then disagreed.
    ran: usize = 0,
    skipped: usize = 0,
    /// Anything wrong: a count mismatch, an unusable FEN, or a `;D<n>` that does
    /// not parse. Each is reported through `w` as well as counted.
    failed: usize = 0,
    nodes: u64 = 0,
};

/// Runs every `;D<n> <nodes>` operation in an EPD text and checks each count.
/// `limit` is what lets the fast and slow test steps share this code instead of
/// keeping a second, drifting copy of the position list.
///
/// `w` receives a line per position when given. A bad record is counted and
/// stepped over rather than abandoning the file after it.
pub fn runSuite(text: []const u8, limit: Limit, w: ?*Io.Writer) !Result {
    var result: Result = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const cut = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const fen = std.mem.trimEnd(u8, line[0..cut], " \t");
        // The suite file comes from outside the program, so it goes through the
        // validating parser rather than `Board.fromFen`.
        var b = movegen.fromFen(fen) catch |err| {
            result.failed += 1;
            if (w) |out| try out.print("FAIL  {s} unusable: {t}\n", .{ fen, err });
            continue;
        };
        result.positions += 1;

        // Operations are `;D<depth> <nodes>`; anything else in the record is not
        // ours to interpret. `D` must be followed by a digit, so EPD's other
        // d-opcodes (`dm`, a direct-mate distance) are passed over rather than
        // reported as malformed.
        var ops = std.mem.splitScalar(u8, line, ';');
        _ = ops.next();
        while (ops.next()) |raw_op| {
            const op = std.mem.trim(u8, raw_op, " \t\r");
            if (op.len < 2 or (op[0] != 'D' and op[0] != 'd')) continue;
            if (!std.ascii.isDigit(op[1])) continue;

            // Past that guard the operation is ours, so a field that will not
            // parse is a fault in the file. Stepping over it quietly leaves a
            // count unchecked with every counter untouched, which reads as
            // success.
            var fields = std.mem.tokenizeAny(u8, op[1..], " \t");
            const depth = parseField(u8, fields.next()) orelse {
                result.failed += 1;
                if (w) |out| try out.print("FAIL  {s} malformed operation ';{s}'\n", .{ fen, op });
                continue;
            };
            const expected = parseField(u64, fields.next()) orelse {
                result.failed += 1;
                if (w) |out| try out.print("FAIL  {s} malformed operation ';{s}'\n", .{ fen, op });
                continue;
            };
            result.ops += 1;

            if (expected > limit.nodes or depth > limit.depth) {
                result.skipped += 1;
                continue;
            }

            const got = perft(&b, depth);
            result.ran += 1;
            result.nodes += got;
            if (got == expected) {
                if (w) |out| try out.print("ok    {s} D{d} {d}\n", .{ fen, depth, got });
            } else {
                result.failed += 1;
                if (w) |out| {
                    try out.print(
                        "FAIL  {s} D{d} expected {d}, got {d}\n",
                        .{ fen, depth, expected, got },
                    );
                }
            }
        }
    }
    return result;
}

/// A missing field and an unparsable one are the same fault to the caller, so
/// they collapse to one null rather than two nearly identical error arms.
fn parseField(comptime T: type, field: ?[]const u8) ?T {
    return std.fmt.parseInt(T, field orelse return null, 10) catch null;
}

/// The oracle file, embedded so tests read exactly what the `epd` command reads.
pub const oracle = @embedFile("perft_epd");

// --- tests --------------------------------------------------------------------------

const attacks = @import("attacks.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Keeps `zig build test` warm-fast while still touching every position in the
/// oracle. Position 4 reaches D3 under this, which is where promotions under
/// check first appear; the deeper counts are `test-slow`'s job.
const fast_limit: Limit = .{ .nodes = 100_000, .depth = 4 };

/// Every `;D` operation in `testdata/perft.epd`, and what they sum to. Stated
/// here rather than read from the file, because a test whose expectations come
/// out of the same file it is checking cannot notice the file changing.
const oracle_ops = 35;
const oracle_nodes: u64 = 16_270_939_707;

test "perft matches the oracle at shallow depth" {
    attacks.init();
    const result = try runSuite(oracle, fast_limit, null);

    try expectEqual(@as(usize, 6), result.positions);
    try expectEqual(@as(usize, oracle_ops), result.ops);
    try expectEqual(@as(usize, 0), result.failed);
    // Every operation is either run or deliberately skipped. Without this one an
    // operation dropped anywhere in the parse leaves no trace at all.
    try expectEqual(result.ops, result.ran + result.skipped);
    try expect(result.ran >= 18);
}

test "deep perft" {
    if (!@import("build_options").slow) return error.SkipZigTest;
    attacks.init();

    const result = try runSuite(oracle, .unlimited, null);
    try expectEqual(@as(usize, 6), result.positions);
    try expectEqual(@as(usize, oracle_ops), result.ops);
    try expectEqual(@as(usize, 0), result.failed);
    // The three that make this run mean something. Under an unlimited budget
    // `skipped == 0` is true by construction, so on its own it proves nothing:
    // `ran` is what says the work happened, and the node total is what says the
    // counts were the ones transcribed from CPW rather than whatever the file
    // happens to hold now.
    try expectEqual(@as(usize, oracle_ops), result.ran);
    try expectEqual(@as(usize, 0), result.skipped);
    try expectEqual(oracle_nodes, result.nodes);
}

test "a suite whose counts stopped parsing fails instead of passing quietly" {
    attacks.init();
    // The transcription slip this guards against: thousands separators, which
    // parse as far as the comma and then stop. Every operation here is dropped
    // by `parseInt`, and before the accounting above that was indistinguishable
    // from a clean run.
    const mangled =
        \\rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ;D1 20 ;D2 4,00
        \\8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1 ;D1 14 ;D2 1,91
    ;
    const result = try runSuite(mangled, .unlimited, null);
    try expectEqual(@as(usize, 2), result.positions);
    try expectEqual(@as(usize, 2), result.ops);
    try expectEqual(@as(usize, 2), result.failed);

    // A record whose FEN is unusable is counted and stepped over, so the
    // positions after it still run.
    const bad_first =
        \\QQQQQQQQ/QQQQQQQQ/8/8/8/8/8/K6k w - - 0 1 ;D1 5
        \\rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ;D1 20
    ;
    const after = try runSuite(bad_first, .unlimited, null);
    try expectEqual(@as(usize, 1), after.positions);
    try expectEqual(@as(usize, 1), after.ran);
    try expectEqual(@as(usize, 1), after.failed);
    try expectEqual(@as(u64, 20), after.nodes);
}

test "the node cap alone does not bound the work; the depth cap does" {
    attacks.init();
    // A count that is wrong low passes any node budget and then runs the full
    // depth anyway. Under the fast limit the depth cap is what stops a mistyped
    // `;D6 1` from turning the turn gate into a 119-million-node job.
    const understated = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 ;D6 1";
    const result = try runSuite(understated, fast_limit, null);
    try expectEqual(@as(usize, 1), result.ops);
    try expectEqual(@as(usize, 1), result.skipped);
    try expectEqual(@as(usize, 0), result.ran);
    try expectEqual(@as(u64, 0), result.nodes);
}

test "perft counts the shallow start position by hand" {
    // The one place the numbers are stated in code rather than read from the
    // oracle file, so a corrupted or truncated embed cannot pass vacuously.
    attacks.init();
    var b = Board.startpos;
    try expectEqual(@as(u64, 1), perft(&b, 0));
    try expectEqual(@as(u64, 20), perft(&b, 1));
    try expectEqual(@as(u64, 400), perft(&b, 2));
    try expectEqual(@as(u64, 8902), perft(&b, 3));
    try expectEqual(@as(u64, 197_281), perft(&b, 4));
}

test "perft leaves the board exactly as it found it" {
    attacks.init();
    var fens = std.mem.splitScalar(u8, oracle, '\n');
    while (fens.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var b = try Board.fromFen(line);
        const before = b;
        _ = perft(&b, 3);
        try expect(std.meta.eql(before, b));
    }
}

test "divide splits the count by root move and sums back to it" {
    attacks.init();
    var b = Board.startpos;

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const total = try divide(&b, 2, &w);

    try expectEqual(perft(&b, 2), total);
    const text = w.buffered();
    // After 1.e4 black has the same twenty replies white started with.
    try expect(std.mem.indexOf(u8, text, "e2e4 20\n") != null);
    try expect(std.mem.endsWith(u8, text, "\n400 nodes\n"));

    // One line per legal root move, plus the blank line and the total.
    var lines: usize = 0;
    for (text) |ch| lines += @intFromBool(ch == '\n');
    try expectEqual(@as(usize, 20 + 2), lines);
}

/// `perft`, checking at every node that the incrementally maintained Zobrist key
/// still matches a full recomputation and that the mailbox matches the bitboards.
///
/// Test-only: both checks are O(64), too expensive for `perft` itself. Nothing
/// else makes them at scale, and a wrong castling-rights or en passant xor
/// changes no node count — it would survive the whole suite and surface later as
/// a transposition-table collision.
fn perftChecked(b: *Board, depth: u8) !u64 {
    try expectEqual(b.computeHash(), b.hash);
    try expect(b.consistent());
    if (depth == 0) return 1;

    var list: MoveList = undefined;
    movegen.generate(b, &list);

    var nodes: u64 = 0;
    for (list.slice()) |m| {
        const undo = move.makeMove(b, m);
        nodes += try perftChecked(b, depth - 1);
        move.unmakeMove(b, m, undo);
    }
    return nodes;
}

test "make and unmake hold the hash and the mailbox at every node" {
    attacks.init();
    // Deeper in the pre-merge run than in the turn gate. Depth 3 over the six
    // oracle positions is ~270k nodes, which the gate can afford.
    const depth: u8 = if (@import("build_options").slow) 4 else 3;

    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, oracle, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var b = try movegen.fromFen(line);
        _ = try perftChecked(&b, depth);
        seen += 1;
    }
    try expectEqual(@as(usize, 6), seen);
}
