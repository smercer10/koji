//! koji — CLI entry point.
//!
//! The engine binary is also the project's tooling: `bench`, `perft` and `epd` are
//! subcommands rather than scripts, so they can never drift out of sync with the
//! engine they measure. This is also what OpenBench expects.
//!
//! The output *shapes* here are contracts — OpenBench parses `bench`, GUIs parse
//! the `uci` block and the `info`/`bestmove` lines — and they were written to
//! their final form before there was anything real behind them, so that only the
//! numbers ever had to change.
//!
//! A `go` runs on its own thread. That is not parallel search (Phase 5); it is
//! what makes `stop` and `go infinite` implementable at all, since the reader
//! would otherwise be blocked on stdin for the whole search. The board belongs
//! to whichever thread is running, and every command that touches it joins the
//! search first — see `Engine.joinSearch`.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const attacks = @import("attacks.zig");
const board = @import("board.zig");
const Board = board.Board;
const movegen = @import("movegen.zig");
const perft_mod = @import("perft.zig");
const move_mod = @import("move.zig");
const Move = move_mod.Move;
const search = @import("search.zig");

/// Bumped per release; reported by `uci` and `--version`.
const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;
    // UCI is a line protocol against a GUI that may be waiting on us, so every
    // command path flushes before it returns rather than relying on scope exit.
    defer out.flush() catch {};

    // Sliding attack tables, before any command runs. Milliseconds, measured —
    // see docs/testlog.md.
    attacks.init();

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) args[1] else "uci";
    const rest = if (args.len > 2) args[2..] else &.{};

    if (eql(command, "uci")) {
        try uciLoop(io, arena, out);
    } else if (eql(command, "bench")) {
        try bench(io, arena, out);
    } else if (eql(command, "perft")) {
        try perftCommand(io, arena, out, rest, .total);
    } else if (eql(command, "divide")) {
        try perftCommand(io, arena, out, rest, .divide);
    } else if (eql(command, "epd")) {
        try epdCommand(io, arena, out, rest);
    } else if (eql(command, "--version") or eql(command, "version")) {
        try out.print("koji {s}\n", .{version});
    } else if (eql(command, "--help") or eql(command, "help")) {
        try usage(out);
    } else {
        try out.print("unknown command: {s}\n\n", .{command});
        try usage(out);
        try out.flush();
        return error.UnknownCommand;
    }
}

fn usage(out: *Io.Writer) Io.Writer.Error!void {
    try out.writeAll(
        \\usage: koji <command>
        \\
        \\  uci                    speak UCI on stdin/stdout (default)
        \\  bench                  fixed benchmark; prints "<nodes> nodes <nps> nps"
        \\  perft <depth> [fen]    node count; start position unless a FEN is given
        \\  divide <depth> [fen]   perft split by root move
        \\  epd <file>             run a perft suite in EPD form
        \\  version                print the version
        \\
    );
}

// --- bench -------------------------------------------------------------------

/// The fixed benchmark: every position in `testdata/bench.epd` searched to
/// `bench_depth`, node counts summed.
///
/// OpenBench parses the last `<nodes> nodes <nps> nps` line off stdout, and the
/// node count must be identical across runs *and across machines* — including
/// between an AVX2 and a non-AVX2 build. That is why every eval path has to stay
/// integer once NNUE lands: floating-point accumulation reorders with SIMD width.
/// Nothing here may consult the clock to decide what to search, for the same
/// reason: only the *reported* nps is allowed to depend on how fast the machine
/// is.
fn bench(io: Io, arena: std.mem.Allocator, out: *Io.Writer) !void {
    return runBench(io, arena, out, bench_depth);
}

/// The depth is a parameter only so the contract test can run the real path
/// cheaply. `bench` itself always uses `bench_depth`.
fn runBench(io: Io, allocator: std.mem.Allocator, out: *Io.Writer, depth: u8) !void {
    const s = try allocator.create(search.Searcher);
    defer allocator.destroy(s);
    s.init(io);

    var nodes: u64 = 0;
    const start = Io.Clock.awake.now(io);

    var positions = benchPositions();
    while (positions.next()) |fen| {
        // A malformed line here is a broken build, not a bad input: the file is
        // embedded at compile time and a test asserts every line parses.
        const b = movegen.fromFen(fen) catch |err| {
            try out.print("bench: unusable position: {s} ({t})\n", .{ fen, err });
            try out.flush();
            return error.InvalidBenchPosition;
        };
        s.setPosition(b);
        s.clearStop();
        nodes += s.search(.{ .depth = depth }, null).nodes;
    }

    const ns = start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
    const nps: u64 = if (ns > 0)
        @intCast(@divTrunc(@as(i96, nodes) * std.time.ns_per_s, ns))
    else
        0;
    try out.print("{d} nodes {d} nps\n", .{ nodes, nps });
}

/// Raising this is expected as move ordering and quiescence land — a deeper
/// bench is a better fingerprint, and today's depth is set by what the search
/// can get through in a second or two without ordering. Every change to it
/// changes the `Bench:` number, which is legitimate *if* docs/testlog.md says so.
const bench_depth = 6;

/// The bench set, embedded rather than read from disk so `koji bench` does not
/// depend on the working directory it is run from — OpenBench does not promise
/// one.
const bench_epd = @embedFile("bench_epd");

/// Yields the FEN on each non-comment, non-blank line. Same shape as the perft
/// suite's file, minus the `;D<n>` operations.
fn benchPositions() BenchPositions {
    return .{ .lines = std.mem.splitScalar(u8, bench_epd, '\n') };
}

const BenchPositions = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(it: *BenchPositions) ?[]const u8 {
        while (it.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

// --- perft -------------------------------------------------------------------

const PerftMode = enum { total, divide };

/// `perft <depth> [fen]` and `divide <depth> [fen]` differ only in what they
/// print, so they share a parser. The FEN is taken as the remaining arguments
/// joined by spaces, which is what a shell hands over for an unquoted one.
fn perftCommand(
    io: Io,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    args: []const []const u8,
    mode: PerftMode,
) !void {
    const name = if (mode == .total) "perft" else "divide";
    if (args.len < 1) {
        try out.print("usage: koji {s} <depth> [fen]\n", .{name});
        try out.flush();
        return error.MissingArgument;
    }
    const depth = std.fmt.parseInt(u8, args[0], 10) catch {
        try out.print("{s}: invalid depth: {s}\n", .{ name, args[0] });
        try out.flush();
        return error.InvalidArgument;
    };

    var b = Board.startpos;
    if (args.len > 1) {
        const fen = try std.mem.join(arena, " ", args[1..]);
        b = movegen.fromFen(fen) catch |err| {
            try out.print("{s}: invalid FEN: {s}\n", .{ name, @errorName(err) });
            try out.flush();
            return error.InvalidArgument;
        };
    }

    switch (mode) {
        .total => {
            // Timed and reported in the same shape as `bench`, because Phase 1's
            // exit criterion is a perft NPS baseline that later work may not
            // regress — and a baseline the binary reports itself is one nobody
            // has to reproduce a shell pipeline to re-measure.
            const start = Io.Clock.awake.now(io);
            const nodes = perft_mod.perft(&b, depth);
            const ns = start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
            const nps: u64 = if (ns > 0)
                @intCast(@divTrunc(@as(i96, nodes) * std.time.ns_per_s, ns))
            else
                0;
            try out.print("{d} nodes {d} nps\n", .{ nodes, nps });
        },
        .divide => _ = try perft_mod.divide(&b, depth, out),
    }
}

// --- epd ---------------------------------------------------------------------

/// Runs a perft suite in EPD form: every `;D<n> <nodes>` operation in the file is
/// checked, and a single failure fails the command. No node budget here — the
/// point of running it by hand is to run all of it.
fn epdCommand(io: Io, arena: std.mem.Allocator, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) {
        try out.writeAll("usage: koji epd <file>\n");
        try out.flush();
        return error.MissingArgument;
    }

    const text = Io.Dir.cwd().readFileAlloc(io, args[0], arena, .limited(16 << 20)) catch |err| {
        try out.print("epd: cannot read {s}: {s}\n", .{ args[0], @errorName(err) });
        try out.flush();
        return error.InvalidArgument;
    };

    const result = perft_mod.runSuite(text, .unlimited, out) catch |err| {
        try out.print("epd: {s}\n", .{@errorName(err)});
        try out.flush();
        return error.InvalidArgument;
    };
    try out.print(
        "\n{d} positions, {d} checks, {d} failed, {d} nodes\n",
        .{ result.positions, result.ran, result.failed, result.nodes },
    );
    try out.flush();
    if (result.failed != 0) return error.PerftMismatch;
}

// --- uci ---------------------------------------------------------------------

/// The stdin line buffer.
///
/// Not on the stack, and not 8KB. `position startpos moves ...` grows by five
/// bytes a ply for the whole game, and `takeDelimiter` answers a line longer
/// than its buffer with `error.StreamTooLong` — which, propagated, kills the
/// engine mid-game. A megabyte is past any legal game's line and cheap enough
/// not to think about.
const line_buffer_bytes = 1 << 20;

/// Depth used when `go` names no limit this engine understands. A GUI at a real
/// time control sends `wtime`/`btime`, which koji parses and ignores until the
/// time-management box lands (ROADMAP Phase 2) — so this is what stands in for
/// a clock, and it is deliberately shallow enough to answer promptly from any
/// position rather than to play well.
const default_depth = 6;

/// Everything a `go` needs that outlives the command that started it. One per
/// process; the searcher is heap-allocated because it is ~50KB of tables.
const Engine = struct {
    io: Io,
    searcher: *search.Searcher,
    out: *Io.Writer,
    /// `info` and `bestmove` come from the search thread while `readyok` can
    /// come from the reader thread at any moment. One writer, two threads, so
    /// the writer is guarded — interleaving them mid-line would corrupt the
    /// protocol, and `isready` during a search is something GUIs really do.
    out_lock: Io.Mutex = .init,
    thread: ?std.Thread = null,

    /// Blocks until no search is running. Every command that touches the board
    /// goes through here first, which is what makes "one writer at a time" true
    /// rather than merely likely.
    fn joinSearch(e: *Engine) void {
        if (e.thread) |t| {
            e.searcher.requestStop();
            t.join();
            e.thread = null;
        }
    }

    fn say(e: *Engine, text: []const u8) void {
        e.out_lock.lockUncancelable(e.io);
        defer e.out_lock.unlock(e.io);
        e.out.writeAll(text) catch {};
        e.out.flush() catch {};
    }
};

fn uciLoop(io: Io, arena: std.mem.Allocator, out: *Io.Writer) !void {
    const stdin_buffer = try arena.alloc(u8, line_buffer_bytes);
    var stdin_file: Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const in = &stdin_file.interface;

    const searcher = try arena.create(search.Searcher);
    searcher.init(io);

    var engine: Engine = .{ .io = io, .searcher = searcher, .out = out };
    // A search still running when stdin ends would outlive the loop and write to
    // a writer that is about to be flushed for the last time.
    defer engine.joinSearch();

    while (true) {
        const next_line = in.takeDelimiter('\n') catch |err| switch (err) {
            // Only reachable past `line_buffer_bytes`, which no legal game comes
            // near. Throw the rest of the oversized line away and keep going:
            // dropping one command beats dropping the process mid-game.
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => |e| return e,
        };
        const raw = next_line orelse return;

        // Tolerate CRLF: some GUIs and most Windows pipes send it.
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        var it = std.mem.tokenizeAny(u8, line, " \t");
        const token = it.next() orelse continue;

        if (eql(token, "uci")) {
            engine.out_lock.lockUncancelable(io);
            defer engine.out_lock.unlock(io);
            try identify(out);
            try out.flush();
        } else if (eql(token, "isready")) {
            // Answered without joining: the spec requires a reply even while a
            // search is running, and that is exactly when a GUI uses it.
            engine.say("readyok\n");
        } else if (eql(token, "ucinewgame")) {
            engine.joinSearch();
            searcher.setPosition(Board.startpos);
        } else if (eql(token, "position")) {
            engine.joinSearch();
            if (!setPosition(searcher, &it)) {
                engine.say("info string position command not understood, position unchanged\n");
            }
        } else if (eql(token, "go")) {
            try startSearch(&engine, &it);
        } else if (eql(token, "stop")) {
            // The search thread prints `bestmove` as it unwinds, so there is
            // nothing to print here — printing one too would send two.
            engine.joinSearch();
        } else if (eql(token, "setoption")) {
            // Phase 2: apply Hash/Threads
        } else if (eql(token, "quit")) {
            engine.joinSearch();
            try out.flush();
            return;
        }
        // Unknown commands are ignored, per the UCI spec.
    }
}

/// `position startpos|fen <fen> [moves <uci>...]`.
///
/// Every move is checked against the legal move list before it is played. A GUI
/// only sends legal moves, but `makeMove` on one that is not is memory-unsafe in
/// a release build — the same class of fault `movegen.legalPosition` exists to
/// stop — and stdin is not ours to trust.
///
/// Returns false if the command could not be applied in full. UCI has no error
/// reply, and the danger in staying quiet is specific: the engine would keep the
/// *previous* position and answer the next `go` with a move that is illegal in
/// the one the GUI thinks it set. The caller turns a false into an `info string`
/// so that failure is visible rather than inferred from a rejected move.
fn setPosition(s: *search.Searcher, it: *std.mem.TokenIterator(u8, .any)) bool {
    const kind = it.next() orelse return false;

    if (eql(kind, "startpos")) {
        s.setPosition(Board.startpos);
    } else if (eql(kind, "fen")) {
        // The FEN is six space-separated fields, but a truncated one is common
        // enough that the parser takes whatever is there up to `moves`.
        var fen_buf: [128]u8 = undefined;
        var len: usize = 0;
        while (it.peek()) |field| {
            if (eql(field, "moves")) break;
            _ = it.next();
            if (len + field.len + 1 > fen_buf.len) return false;
            if (len > 0) {
                fen_buf[len] = ' ';
                len += 1;
            }
            @memcpy(fen_buf[len..][0..field.len], field);
            len += field.len;
        }
        s.setPosition(movegen.fromFen(fen_buf[0..len]) catch return false);
    } else {
        return false;
    }

    const moves = it.next() orelse return true;
    if (!eql(moves, "moves")) return false;

    while (it.next()) |text| {
        const m = Move.fromUci(&s.b, text) orelse return false;
        var list: movegen.MoveList = undefined;
        movegen.generate(&s.b, &list);
        for (list.slice()) |legal| {
            if (@as(u16, @bitCast(legal)) == @as(u16, @bitCast(m))) {
                s.playMove(m);
                break;
            }
        } else return false;
    }
    return true;
}

/// `go [depth n] [nodes n] [movetime ms] [infinite] [wtime ms] ...`.
///
/// Every limit is an independent ceiling and the search stops at whichever binds
/// first, so `go depth 4 nodes 500000` means both and not whichever was typed
/// last. `search.Limits` starts wide open and each token only ever narrows it —
/// writing `max_ply` back into `depth` to mean "no depth limit" is what made
/// this order-dependent before.
fn parseLimits(it: *std.mem.TokenIterator(u8, .any)) search.Limits {
    var limits: search.Limits = .{};
    var bounded = false;

    while (it.next()) |token| {
        if (eql(token, "infinite")) {
            // Already the default: every ceiling is open.
            bounded = true;
        } else if (eql(token, "depth")) {
            // Parsed wide, then clamped. A `u8` here would wrap `go depth 1000`
            // into a parse failure and silently fall back to `default_depth`.
            const requested = parseNext(u32, it) orelse continue;
            limits.depth = @intCast(@min(requested, search.max_ply));
            bounded = true;
        } else if (eql(token, "nodes")) {
            limits.nodes = parseNext(u64, it) orelse continue;
            bounded = true;
        } else if (eql(token, "movetime")) {
            limits.movetime_ms = parseNext(u64, it) orelse continue;
            bounded = true;
        }
        // wtime/btime/winc/binc/movestogo are consumed and ignored: koji has no
        // clock yet. ROADMAP.
    }

    // A `go` carrying only a clock koji cannot read would otherwise search to
    // `max_ply` and never come back.
    if (!bounded) limits.depth = default_depth;
    return limits;
}

fn startSearch(e: *Engine, it: *std.mem.TokenIterator(u8, .any)) !void {
    e.joinSearch();
    const limits = parseLimits(it);

    // Armed here rather than inside the search: a `stop` can arrive before the
    // thread reaches its first node, and clearing it there would swallow it.
    e.searcher.clearStop();

    e.thread = std.Thread.spawn(.{}, runSearch, .{ e, limits }) catch {
        // No thread available: search on this thread instead. `stop` cannot be
        // heard while that runs, which is worse than the alternative but far
        // better than never answering a `go`.
        runSearch(e, limits);
        return;
    };
}

fn runSearch(e: *Engine, limits: search.Limits) void {
    const result = e.searcher.search(limits, .{ .ctx = e, .emit = emitInfo });

    e.out_lock.lockUncancelable(e.io);
    defer e.out_lock.unlock(e.io);
    if (result.move) |m| {
        e.out.print("bestmove {f}\n", .{m}) catch {};
    } else {
        // No legal move: the game is over. UCI has no better spelling than the
        // null move, and a GUI that gets nothing at all will hang.
        e.out.writeAll("bestmove 0000\n") catch {};
    }
    e.out.flush() catch {};
}

fn emitInfo(ctx: *anyopaque, info: search.Info) void {
    const e: *Engine = @ptrCast(@alignCast(ctx));
    e.out_lock.lockUncancelable(e.io);
    defer e.out_lock.unlock(e.io);
    writeInfo(e.out, info) catch {};
    e.out.flush() catch {};
}

/// `info depth <d> score cp <x>|mate <n> nodes <n> nps <n> time <ms> pv <moves>`.
fn writeInfo(w: *Io.Writer, info: search.Info) Io.Writer.Error!void {
    try w.print("info depth {d} score ", .{info.depth});
    if (search.mateDistance(info.score)) |moves| {
        try w.print("mate {d}", .{moves});
    } else {
        try w.print("cp {d}", .{info.score});
    }

    const nps: u64 = if (info.elapsed_ns > 0)
        @intCast(@divTrunc(@as(u128, info.nodes) * std.time.ns_per_s, info.elapsed_ns))
    else
        0;
    const time_ms = info.elapsed_ns / std.time.ns_per_ms;
    try w.print(" nodes {d} nps {d} time {d} pv", .{ info.nodes, nps, time_ms });
    for (info.pv) |m| try w.print(" {f}", .{m});
    try w.writeByte('\n');
}

fn parseNext(comptime T: type, it: *std.mem.TokenIterator(u8, .any)) ?T {
    return std.fmt.parseInt(T, it.next() orelse return null, 10) catch null;
}

fn identify(out: *Io.Writer) Io.Writer.Error!void {
    try out.print("id name koji {s}\n", .{version});
    try out.writeAll("id author koji contributors\n");

    // Hash and Threads are mandatory for OpenBench and expected by every GUI.
    try out.writeAll("option name Hash type spin default 16 min 1 max 65536\n");
    try out.writeAll("option name Threads type spin default 1 min 1 max 256\n");

    // Tuning knobs appear only in a -Dtunables build. A release must advertise
    // nothing here beyond the real options above.
    if (build_options.tunables) {
        try out.writeAll("option name TunableExample type spin default 100 min 1 max 1000\n");
    }

    try out.writeAll("uciok\n");
}

// --- helpers -----------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- tests -------------------------------------------------------------------

test {
    // Pulls the engine modules into the test graph: a file whose tests nothing
    // references is silently untested (CLAUDE.md).
    _ = @import("board.zig");
    _ = @import("move.zig");
    _ = @import("attacks.zig");
    _ = @import("movegen.zig");
    _ = @import("perft.zig");
    _ = @import("eval.zig");
    _ = @import("search.zig");
}

test "bench output matches the OpenBench contract" {
    attacks.init();
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // Depth 1 so the turn gate stays cheap; every other part of the path — the
    // embedded file, the FEN parsing, the summing, the line format — is the one
    // `koji bench` runs.
    try runBench(std.testing.io, std.testing.allocator, &w, 1);

    const line = std.mem.trimEnd(u8, w.buffered(), "\n");
    var it = std.mem.tokenizeScalar(u8, line, ' ');

    _ = try std.fmt.parseInt(u64, it.next().?, 10);
    try std.testing.expectEqualStrings("nodes", it.next().?);
    _ = try std.fmt.parseInt(u64, it.next().?, 10);
    try std.testing.expectEqualStrings("nps", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "uci identifies, advertises Hash and Threads, and terminates with uciok" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try identify(&w);
    const text = w.buffered();

    try std.testing.expect(std.mem.startsWith(u8, text, "id name koji"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\noption name Hash type spin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\noption name Threads type spin") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "uciok\n"));
}

test "a release build advertises no tuning options" {
    if (build_options.tunables) return error.SkipZigTest;

    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try identify(&w);

    // Every advertised option must be one a GUI actually knows about.
    var lines = std.mem.tokenizeScalar(u8, w.buffered(), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "option name ")) continue;
        const name = std.mem.sliceTo(line["option name ".len..], ' ');
        try std.testing.expect(eql(name, "Hash") or eql(name, "Threads"));
    }
}

// The perft tests, shallow and deep, live in `perft.zig` beside the driver they
// exercise; `zig build test-slow` still reaches them through the import above.

test "every bench position is legal, and the set is the size it claims" {
    attacks.init();
    var count: usize = 0;
    var positions = benchPositions();
    while (positions.next()) |fen| {
        // The same validating parser `bench` uses, so a typo in the data file
        // fails here rather than as a mysterious change in the bench number.
        _ = try movegen.fromFen(fen);
        count += 1;
    }
    // A tripwire, not a preference: changing the set changes every future
    // `Bench:` line, so it should take a deliberate edit in two places.
    try std.testing.expectEqual(@as(usize, 16), count);
}

test "info lines carry a score the protocol understands" {
    var buf: [256]u8 = undefined;

    var w: Io.Writer = .fixed(&buf);
    try writeInfo(&w, .{
        .depth = 7,
        .score = -34,
        .nodes = 1000,
        .elapsed_ns = 2 * std.time.ns_per_ms,
        .pv = &.{},
    });
    try std.testing.expectEqualStrings(
        "info depth 7 score cp -34 nodes 1000 nps 500000 time 2 pv\n",
        w.buffered(),
    );

    // A forced mate is spelled `mate <moves>`, never as a huge cp value: a GUI
    // reading 31999 centipawns shows +319.99, not "mate in 1".
    w = .fixed(&buf);
    try writeInfo(&w, .{
        .depth = 3,
        .score = search.mate_score - 1,
        .nodes = 10,
        .elapsed_ns = 0,
        .pv = &.{},
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), " score mate 1 ") != null);
}

test "position replays a game and refuses a move that is not legal" {
    attacks.init();
    const s = try std.testing.allocator.create(search.Searcher);
    defer std.testing.allocator.destroy(s);
    s.init(std.testing.io);

    var good = std.mem.tokenizeAny(u8, "startpos moves e2e4 e7e5 g1f3", " \t");
    try std.testing.expect(setPosition(s, &good));
    try std.testing.expectEqual(Board.startpos.hash, s.history[0]);
    try std.testing.expectEqual(@as(usize, 4), s.root_history_len);
    try std.testing.expect(s.b.consistent());

    // `e2e4` is well-formed but not legal here, and playing it would move a
    // piece that is not there. The replay has to stop, not corrupt the board.
    var bad = std.mem.tokenizeAny(u8, "startpos moves e2e4 e2e4", " \t");
    try std.testing.expect(!setPosition(s, &bad));
    try std.testing.expectEqual(@as(usize, 2), s.root_history_len);
    try std.testing.expect(s.b.consistent());
    try std.testing.expectEqual(s.b.hash, s.b.computeHash());

    // A FEN position, and a move played from it.
    var fen = std.mem.tokenizeAny(u8, "fen 6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1 moves a1a8", " \t");
    try std.testing.expect(setPosition(s, &fen));
    try std.testing.expect(s.b.consistent());
    try std.testing.expectEqual(board.Color.black, s.b.side);
    try std.testing.expectEqual(board.Piece.w_rook, s.b.pieceAt(.a8));
}

test "a rejected position leaves the board alone and says so" {
    attacks.init();
    const s = try std.testing.allocator.create(search.Searcher);
    defer std.testing.allocator.destroy(s);
    s.init(std.testing.io);

    var start = std.mem.tokenizeAny(u8, "startpos moves d2d4", " \t");
    try std.testing.expect(setPosition(s, &start));
    const established = s.b.hash;

    // An unparseable FEN must not silently leave the engine on the previous
    // position with no signal: the next `go` would answer with a move that is
    // illegal in the position the GUI believes it set.
    var junk = std.mem.tokenizeAny(u8, "fen not/a/valid/fen w - - 0 1", " \t");
    try std.testing.expect(!setPosition(s, &junk));
    try std.testing.expectEqual(established, s.b.hash);

    var unknown = std.mem.tokenizeAny(u8, "sideways", " \t");
    try std.testing.expect(!setPosition(s, &unknown));
    try std.testing.expectEqual(established, s.b.hash);
}

test "every go limit is a ceiling, whatever order they arrive in" {
    // Each limit used to be applied by writing `max_ply` back into `depth` to
    // mean "no depth limit", which made `go depth 4 nodes N` depend on which
    // token came last. They are independent ceilings.
    const both_orders = [_][]const u8{
        "depth 4 nodes 999999999",
        "nodes 999999999 depth 4",
    };
    for (both_orders) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const limits = parseLimits(&it);
        try std.testing.expectEqual(@as(u8, 4), limits.depth);
        try std.testing.expectEqual(@as(u64, 999999999), limits.nodes);
    }

    var deep = std.mem.tokenizeAny(u8, "depth 3 movetime 2000", " \t");
    const mixed = parseLimits(&deep);
    try std.testing.expectEqual(@as(u8, 3), mixed.depth);
    try std.testing.expectEqual(@as(?u64, 2000), mixed.movetime_ms);
}

test "go depth clamps instead of wrapping" {
    // Parsed as u8, `depth 1000` overflowed into a parse failure and quietly
    // fell back to `default_depth` — the opposite of what was asked for.
    for ([_][]const u8{ "depth 1000", "depth 4294967295" }) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        try std.testing.expectEqual(@as(u8, search.max_ply), parseLimits(&it).depth);
    }

    var junk = std.mem.tokenizeAny(u8, "depth banana", " \t");
    try std.testing.expectEqual(@as(u8, default_depth), parseLimits(&junk).depth);
}

test "a go with no limit koji understands still terminates" {
    // A clock-only `go` is what a GUI at a real time control sends. koji cannot
    // read it yet, and must not answer by searching to `max_ply`.
    var clock = std.mem.tokenizeAny(u8, "wtime 60000 btime 60000 winc 600 binc 600", " \t");
    try std.testing.expectEqual(@as(u8, default_depth), parseLimits(&clock).depth);

    var bare = std.mem.tokenizeAny(u8, "", " \t");
    try std.testing.expectEqual(@as(u8, default_depth), parseLimits(&bare).depth);

    // `infinite` is the one that genuinely means "no ceiling".
    var forever = std.mem.tokenizeAny(u8, "infinite", " \t");
    const unlimited = parseLimits(&forever);
    try std.testing.expectEqual(@as(u8, search.max_ply), unlimited.depth);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), unlimited.nodes);
    try std.testing.expectEqual(@as(?u64, null), unlimited.movetime_ms);
}
