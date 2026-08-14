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
    var list: MoveList = undefined;
    movegen.generate(b, &list);

    var total: u64 = 0;
    for (list.slice()) |m| {
        const undo = move.makeMove(b, m);
        const nodes = if (depth == 0) 0 else perft(b, depth - 1);
        move.unmakeMove(b, m, undo);

        try w.print("{f} {d}\n", .{ m, nodes });
        total += nodes;
    }
    try w.print("\n{d} nodes\n", .{total});
    return total;
}

// --- EPD suite ----------------------------------------------------------------------

pub const Result = struct {
    positions: usize = 0,
    /// Perft calls actually run — the ones over `budget` are not.
    ran: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    nodes: u64 = 0,
};

/// Runs every `;D<n> <nodes>` operation in an EPD text and checks each count.
///
/// `budget` caps the *expected* node count of any single perft, which is what
/// lets the fast test step share this code with the slow one instead of keeping a
/// second, drifting copy of the position list. Deciding on the expected count
/// rather than a timer keeps the set of work identical on every machine.
///
/// `w` receives a line per position when given; failures are reported through it
/// and counted in the result either way.
pub fn runSuite(text: []const u8, budget: u64, w: ?*Io.Writer) !Result {
    var result: Result = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const cut = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const fen = std.mem.trimEnd(u8, line[0..cut], " \t");
        // The suite file comes from outside the program, so it goes through the
        // validating parser rather than `Board.fromFen`.
        var b = try movegen.fromFen(fen);
        result.positions += 1;

        // Operations are `;D<depth> <nodes>`; anything else in the record is not
        // ours to interpret.
        var ops = std.mem.splitScalar(u8, line, ';');
        _ = ops.next();
        while (ops.next()) |raw_op| {
            const op = std.mem.trim(u8, raw_op, " \t\r");
            if (op.len < 2 or (op[0] != 'D' and op[0] != 'd')) continue;

            var fields = std.mem.tokenizeAny(u8, op[1..], " \t");
            const depth = std.fmt.parseInt(u8, fields.next() orelse continue, 10) catch continue;
            const expected = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;

            if (expected > budget) {
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

/// The oracle file, embedded so tests read exactly what the `epd` command reads.
pub const oracle = @embedFile("perft_epd");

// --- tests --------------------------------------------------------------------------

const attacks = @import("attacks.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Keeps `zig build test` warm-fast while still touching every position in the
/// oracle. Position 4 reaches D3 under this, which is where promotions under
/// check first appear; the deeper counts are `test-slow`'s job.
const fast_budget: u64 = 100_000;

test "perft matches the oracle at shallow depth" {
    attacks.init();
    const result = try runSuite(oracle, fast_budget, null);

    try expectEqual(@as(usize, 6), result.positions);
    try expectEqual(@as(usize, 0), result.failed);
    // Without this a budget that skipped everything would pass silently.
    try expect(result.ran >= 18);
}

test "deep perft" {
    if (!@import("build_options").slow) return error.SkipZigTest;
    attacks.init();

    const result = try runSuite(oracle, std.math.maxInt(u64), null);
    try expectEqual(@as(usize, 6), result.positions);
    try expectEqual(@as(usize, 0), result.skipped);
    try expectEqual(@as(usize, 0), result.failed);
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
