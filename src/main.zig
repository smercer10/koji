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
const tt = @import("tt.zig");

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

    // Always `default_hash_mb`, never whatever `Hash` was set to: the table size
    // decides how much of the tree is remembered, so a bench that inherited it
    // would print a different number on the same binary.
    var table: tt.Table = try .init(allocator, default_hash_mb);
    defer table.deinit(allocator);
    s.init(io, &table);

    var nodes: u64 = 0;
    const start = Io.Clock.awake.now(io);

    var positions = benchPositions();
    while (positions.next()) |fen| {
        // Cleared between positions, so each one's node count is a function of
        // that position alone: the bench stays a sum of independent numbers, and
        // a regression can be attributed to the position that shows it rather
        // than to the one that happened to run before it.
        table.clear();
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

/// Transposition table size, in megabytes. One constant for the value `uci`
/// advertises as `Hash`'s default, the size the table is actually allocated at,
/// and the size `bench` runs with — a bench measured against a table of one size
/// and advertised as another is the kind of mismatch nobody thinks to check.
///
/// The default only; `setoption name Hash` moves it within the bounds below.
const default_hash_mb = 16;

/// What `uci` advertises and what `setoption` clamps to, from one pair of
/// constants so the promise and its enforcement cannot drift apart.
const min_hash_mb = 1;
const max_hash_mb = 65536;

/// `max_threads` is 1 because koji searches on one thread until Lazy SMP (Phase
/// 5) — OpenBench documents that exact narrow range for engines without parallel
/// search, so do not widen it to look compatible. Widening it and disclaiming the
/// truth in an `info string` is the specific fix to avoid: cutechess-cli hides
/// `info string` without `-debug`, so the disclaimer is invisible in the
/// automated runs where the overclaim would matter.
/// via https://github.com/AndyGrant/OpenBench/wiki/Requirements-For-Public-Engines
const min_threads = 1;
const max_threads = 1;

/// Depth used when `go` names no limit at all — not even a clock. Such a `go`
/// states no ceiling, so honouring it literally means searching until `stop`,
/// and a GUI that never sends one would hang the engine. koji bounds it
/// instead. Deliberately shallow: it exists to answer promptly, not to play
/// well.
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
    /// Set from dispatch until `runSearch` has written its `bestmove`. Read
    /// through `searchLive`, never directly.
    searching: std.atomic.Value(bool) = .init(false),

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

    /// Whether a search is running. **Not `thread != null`**: only a join clears
    /// that, so a `go` that ended on its own leaves it set indefinitely and a
    /// caller testing it would refuse every later command for the rest of the
    /// game. Reaping here cannot block — `runSearch` clears the flag last.
    fn searchLive(e: *Engine) bool {
        if (e.thread == null) return false;
        if (e.searching.load(.acquire)) return true;
        e.joinSearch();
        return false;
    }

    fn say(e: *Engine, text: []const u8) void {
        e.out_lock.lockUncancelable(e.io);
        defer e.out_lock.unlock(e.io);
        e.out.writeAll(text) catch {};
        e.out.flush() catch {};
    }

    /// `say` with a format string. Too long is dropped, not truncated — half an
    /// `info string` is not better than none.
    fn sayFmt(e: *Engine, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        e.say(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }
};

/// Bounds how much of a GUI-supplied name or value an `info string` echoes.
/// stdin is not ours to bound, and an unbounded `{s}` of it overflows `sayFmt`
/// and drops the very message reporting the problem.
const echo_limit = 64;

fn echo(text: []const u8) []const u8 {
    return text[0..@min(text.len, echo_limit)];
}

fn uciLoop(io: Io, arena: std.mem.Allocator, out: *Io.Writer) !void {
    const stdin_buffer = try arena.alloc(u8, line_buffer_bytes);
    var stdin_file: Io.File.Reader = .init(.stdin(), io, stdin_buffer);
    const in = &stdin_file.interface;

    const searcher = try arena.create(search.Searcher);
    // Not the arena, unlike everything else here: `setoption name Hash`
    // reallocates this, and an arena never hands memory back, so every resize
    // would leak the table it replaced.
    const table_allocator = std.heap.page_allocator;
    var table: tt.Table = try .init(table_allocator, default_hash_mb);
    defer table.deinit(table_allocator);
    searcher.init(io, &table);

    var engine: Engine = .{ .io = io, .searcher = searcher, .out = out };
    // A search still running when stdin ends would outlive the loop and write to
    // a writer that is about to be flushed for the last time. Registered after
    // the table's defer so it runs before it — the reverse frees the table under
    // a live search thread.
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
            // Joined first: the table belongs to whichever thread is running,
            // and clearing it under a live search would be a data race as well
            // as nonsense.
            table.clear();
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
            applyOption(&engine, table_allocator, it.rest());
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

/// `go [depth n] [nodes n] [movetime ms] [infinite] [wtime ms] [winc ms] ...`.
///
/// Every limit is an independent ceiling and the search stops at whichever binds
/// first, so `go depth 4 nodes 500000` means both and not whichever was typed
/// last. `search.Limits` starts wide open and each token only ever narrows it —
/// writing `max_ply` back into `depth` to mean "no depth limit" is what made
/// this order-dependent before.
///
/// `side` is the side to move in the position the search will start from: UCI
/// sends both players' clocks on every `go` and expects the engine to know which
/// one is its own. Resolving it here keeps `search.zig` free of the protocol's
/// colours; what it receives is one clock, already the right one.
fn parseLimits(it: *std.mem.TokenIterator(u8, .any), side: board.Color) search.Limits {
    var limits: search.Limits = .{};
    var bounded = false;

    // Assembled across the loop because the five clock tokens arrive in any
    // order and mean nothing individually — a `winc` with no `wtime` is not a
    // time control, so the clock is only attached below if a real one was named.
    var remaining_ms: ?u64 = null;
    var increment_ms: u64 = 0;
    var movestogo: ?u32 = null;
    const white = side == .white;

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
        } else if (eql(token, "wtime") or eql(token, "btime")) {
            // Both colours are matched and their argument consumed either way,
            // so that the opponent's number cannot come back round the loop as
            // a token in its own right. Only ours is kept.
            const ms = parseNext(u64, it) orelse continue;
            if (eql(token, if (white) "wtime" else "btime")) {
                remaining_ms = ms;
                bounded = true;
            }
        } else if (eql(token, "winc") or eql(token, "binc")) {
            const ms = parseNext(u64, it) orelse continue;
            if (eql(token, if (white) "winc" else "binc")) increment_ms = ms;
        } else if (eql(token, "movestogo")) {
            movestogo = parseNext(u32, it) orelse continue;
        }
    }

    if (remaining_ms) |ms| limits.clock = .{
        .remaining_ms = ms,
        .increment_ms = increment_ms,
        .movestogo = movestogo,
    };

    // Nothing named at all — not a depth, not a clock. Without this the search
    // runs to `max_ply` and never comes back.
    if (!bounded) limits.depth = default_depth;
    return limits;
}

// --- setoption ---------------------------------------------------------------

const Option = struct {
    name: []const u8,
    /// Absent rather than empty when the line carried no `value` at all, which
    /// is what a `button`-type option sends and is not an error.
    value: ?[]const u8,
};

/// `name <id> [value <x>]`, over everything after the `setoption` token.
///
/// **Do not tokenise the name**: option names contain spaces, and `Move
/// Overhead` is already coming in Phase 3. The literal `value` delimits, and the
/// value keeps its spaces because a `string` option's value is free text.
/// Leftmost `value` wins — the other rule breaks a value containing the word.
///
/// Null means the line was not a `setoption` at all; an empty name is not, and
/// the caller reports it as unknown.
fn parseOption(rest: []const u8) ?Option {
    // `name` and `value` are protocol literals, matched exactly. Only the option
    // name is matched loosely, at the call site.
    const text = std.mem.trim(u8, rest, " \t");
    if (!std.mem.startsWith(u8, text, "name")) return null;

    const after = text["name".len..];
    // `name` has to be a whole token, or `nameHash` would parse as this command.
    if (after.len != 0 and after[0] != ' ' and after[0] != '\t') return null;

    var it = std.mem.tokenizeAny(u8, after, " \t");
    var name_end: usize = 0;
    while (it.next()) |token| {
        if (eql(token, "value")) return .{
            .name = std.mem.trim(u8, after[0..name_end], " \t"),
            .value = std.mem.trim(u8, it.rest(), " \t"),
        };
        name_end = it.index;
    }
    return .{ .name = std.mem.trim(u8, after, " \t"), .value = null };
}

/// The integer `text` denotes, saturating rather than failing when it is too
/// large for `i64`. Null only when it is not a number at all.
///
/// **Signed on purpose** — an unsigned parse turns `-1` into "is not a number",
/// applying a harsher rule to one direction of the same mistake. `-1` and 10^30
/// are out-of-range numbers, and the caller clamps them like any other.
fn spinValue(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
        error.Overflow => if (text.len != 0 and text[0] == '-')
            std.math.minInt(i64)
        else
            std.math.maxInt(i64),
        error.InvalidCharacter => null,
    };
}

/// The value of a spin option, clamped to the range `uci` advertised. Clamping
/// rather than rejecting: an out-of-range value still says which direction the
/// GUI wants. Null is the different case of no usable number at all.
fn optionValue(e: *Engine, opt: Option, min: i64, max: i64) ?i64 {
    const text = opt.value orelse {
        e.sayFmt("info string option {s} needs a value\n", .{echo(opt.name)});
        return null;
    };
    const n = spinValue(text) orelse {
        e.sayFmt("info string option {s} value {s} is not a number\n", .{
            echo(opt.name),
            echo(text),
        });
        return null;
    };
    const clamped = std.math.clamp(n, min, max);
    if (clamped != n) e.sayFmt("info string {s} {d} out of range, clamped to {d}\n", .{
        echo(opt.name),
        n,
        clamped,
    });
    return clamped;
}

/// `setoption name <id> [value <x>]`. UCI has no error reply, so every failure
/// here is an `info string` — silence would leave a GUI believing it had set
/// something it had not.
fn applyOption(e: *Engine, allocator: std.mem.Allocator, rest: []const u8) void {
    // **Refuse, do not join.** Unlike every other command here, `joinSearch`
    // would make the search print a `bestmove` the GUI never asked for and may
    // play — and a `Hash` resize would free a table the search is reading. The
    // spec only sends `setoption` when the engine is waiting, so this costs one
    // out-of-spec command.
    if (e.searchLive()) {
        e.say("info string setoption ignored during a search\n");
        return;
    }

    const opt = parseOption(rest) orelse {
        e.say("info string setoption command not understood\n");
        return;
    };

    if (std.ascii.eqlIgnoreCase(opt.name, "Hash")) {
        // Non-negative by construction: the clamp floor is `min_hash_mb`.
        const mb: usize = @intCast(optionValue(e, opt, min_hash_mb, max_hash_mb) orelse return);
        e.searcher.tt.resize(allocator, mb) catch {
            // Still live: `Table.resize` allocates before it frees for this case.
            e.sayFmt("info string Hash {d} could not be allocated, keeping {d}MB\n", .{
                mb,
                e.searcher.tt.allocatedMb(),
            });
            return;
        };
        // Quiet on an exact fit; `init` rounds down, so anything else got less
        // than it asked for and should hear so.
        const got = e.searcher.tt.allocatedMb();
        if (got != mb) e.sayFmt("info string Hash {d} rounded down to {d}MB\n", .{ mb, got });
    } else if (std.ascii.eqlIgnoreCase(opt.name, "Threads")) {
        // Discarded deliberately: at `max_threads` 1 the only value this yields
        // is the one koji already runs at, so a field to hold it could not vary.
        // Phase 5 adds one. The clamp is what this branch buys today.
        _ = optionValue(e, opt, min_threads, max_threads) orelse return;
    } else {
        e.sayFmt("info string unknown option {s}\n", .{echo(opt.name)});
    }
}

fn startSearch(e: *Engine, it: *std.mem.TokenIterator(u8, .any)) !void {
    e.joinSearch();
    // Read after the join: the side to move is only settled once any previous
    // search has stopped touching the board.
    const limits = parseLimits(it, e.searcher.b.side);

    // Armed here rather than inside the search: a `stop` can arrive before the
    // thread reaches its first node, and clearing it there would swallow it.
    e.searcher.clearStop();
    // Before the spawn for the same reason: `searchLive` can be asked before the
    // new thread runs an instruction.
    e.searching.store(true, .release);

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

    {
        e.out_lock.lockUncancelable(e.io);
        defer e.out_lock.unlock(e.io);
        if (result.move) |m| {
            e.out.print("bestmove {f}\n", .{m}) catch {};
        } else {
            // No legal move: the game is over. UCI has no better spelling than
            // the null move, and a GUI that gets nothing at all will hang.
            e.out.writeAll("bestmove 0000\n") catch {};
        }
        e.out.flush() catch {};
    }

    // Last, and outside the lock: this releases the reader thread, which must not
    // accept a command while `bestmove` is still unwritten.
    e.searching.store(false, .release);
}

fn emitInfo(ctx: *anyopaque, info: search.Info) void {
    const e: *Engine = @ptrCast(@alignCast(ctx));
    e.out_lock.lockUncancelable(e.io);
    defer e.out_lock.unlock(e.io);
    writeInfo(e.out, info) catch {};
    e.out.flush() catch {};
}

/// `info depth <d> score cp <x>|mate <n> nodes <n> nps <n> hashfull <permill>
/// time <ms> pv <moves>`.
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
    try w.print(" nodes {d} nps {d} hashfull {d} time {d} pv", .{
        info.nodes,
        nps,
        info.hashfull,
        time_ms,
    });
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
    try out.print("option name Hash type spin default {d} min {d} max {d}\n", .{
        default_hash_mb,
        min_hash_mb,
        max_hash_mb,
    });
    try out.print("option name Threads type spin default {d} min {d} max {d}\n", .{
        min_threads,
        min_threads,
        max_threads,
    });

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
    _ = @import("tt.zig");
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

test "setoption splits a name from a value at the `value` token" {
    const expectOption = struct {
        fn f(rest: []const u8, name: []const u8, value: ?[]const u8) !void {
            const opt = parseOption(rest) orelse return error.NotParsed;
            try std.testing.expectEqualStrings(name, opt.name);
            if (value) |v| {
                try std.testing.expectEqualStrings(v, opt.value orelse return error.NoValue);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), opt.value);
            }
        }
    }.f;

    try expectOption("name Hash value 32", "Hash", "32");
    // The case a token-per-field parser gets wrong, and the reason this function
    // exists: `Move Overhead` is already named in search.zig as a Phase 3 option.
    try expectOption("name Move Overhead value 30", "Move Overhead", "30");
    // A `string`-type value is free text, so the value keeps its spaces too.
    try expectOption("name SyzygyPath value /a/b /c/d", "SyzygyPath", "/a/b /c/d");
    // No `value` at all is a `button`-type option, not a malformed line.
    try expectOption("name Clear Hash", "Clear Hash", null);
    // Leftmost `value` wins — documented on `parseOption`, pinned here.
    try expectOption("name Foo value bar value baz", "Foo", "bar value baz");
    // Whatever spacing a GUI uses, including the tabs the loop already tolerates.
    try expectOption("  name\tHash\tvalue\t64  ", "Hash", "64");
    // Case is preserved rather than folded: matching loosely is the caller's job.
    try expectOption("name hAsH value 1", "hAsH", "1");
    // An empty name parses, and is reported as an unknown option like any other.
    try expectOption("name value 5", "", "5");

    // Not a `setoption` body at all.
    try std.testing.expectEqual(@as(?Option, null), parseOption(""));
    try std.testing.expectEqual(@as(?Option, null), parseOption("value 32"));
    // `name` must be a whole token, or this would set an option called "Hash".
    try std.testing.expectEqual(@as(?Option, null), parseOption("nameHash value 32"));
}

test "a spin value is a number or nothing, and never an error for being extreme" {
    // The point of the signed, saturating parse: every one of these is a number
    // out of range, and the caller clamps them all the same way. An unsigned
    // parse would call the negative one unreadable instead.
    try std.testing.expectEqual(@as(?i64, 32), spinValue("32"));
    try std.testing.expectEqual(@as(?i64, -1), spinValue("-1"));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), spinValue("999999999999999999999"));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), spinValue("-999999999999999999999"));

    // Not numbers at all, which is the one case the caller reports rather than
    // clamps.
    try std.testing.expectEqual(@as(?i64, null), spinValue("abc"));
    try std.testing.expectEqual(@as(?i64, null), spinValue(""));
    try std.testing.expectEqual(@as(?i64, null), spinValue("12x"));
}

test "a resized table is the size Hash asked for, rounded down" {
    // The engine-side path is covered by tt.zig's own resize test; this pins the
    // conversion `applyOption` reports back to the GUI, which is where a
    // rounded-down request has to stop being invisible.
    var t: tt.Table = try .init(std.testing.allocator, 16);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), t.allocatedMb());

    try t.resize(std.testing.allocator, 3);
    try std.testing.expectEqual(@as(usize, 2), t.allocatedMb());

    try t.resize(std.testing.allocator, 64);
    try std.testing.expectEqual(@as(usize, 64), t.allocatedMb());
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
        .hashfull = 128,
        .pv = &.{},
    });
    try std.testing.expectEqualStrings(
        "info depth 7 score cp -34 nodes 1000 nps 500000 hashfull 128 time 2 pv\n",
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
        .hashfull = 0,
        .pv = &.{},
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), " score mate 1 ") != null);
}

test "position replays a game and refuses a move that is not legal" {
    attacks.init();
    const s = try std.testing.allocator.create(search.Searcher);
    defer std.testing.allocator.destroy(s);
    // No table: `setPosition` never searches, so there is nothing to remember.
    var no_table: tt.Table = .off;
    s.init(std.testing.io, &no_table);

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
    // No table: `setPosition` never searches, so there is nothing to remember.
    var no_table: tt.Table = .off;
    s.init(std.testing.io, &no_table);

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
        const limits = parseLimits(&it, .white);
        try std.testing.expectEqual(@as(u8, 4), limits.depth);
        try std.testing.expectEqual(@as(u64, 999999999), limits.nodes);
    }

    var deep = std.mem.tokenizeAny(u8, "depth 3 movetime 2000", " \t");
    const mixed = parseLimits(&deep, .white);
    try std.testing.expectEqual(@as(u8, 3), mixed.depth);
    try std.testing.expectEqual(@as(?u64, 2000), mixed.movetime_ms);
}

test "go depth clamps instead of wrapping" {
    // Parsed as u8, `depth 1000` overflowed into a parse failure and quietly
    // fell back to `default_depth` — the opposite of what was asked for.
    for ([_][]const u8{ "depth 1000", "depth 4294967295" }) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        try std.testing.expectEqual(@as(u8, search.max_ply), parseLimits(&it, .white).depth);
    }

    var junk = std.mem.tokenizeAny(u8, "depth banana", " \t");
    try std.testing.expectEqual(@as(u8, default_depth), parseLimits(&junk, .white).depth);
}

test "a go with no limit koji understands still terminates" {
    // Only a `go` naming nothing at all falls back now. A clock-only `go` is
    // bounded by the clock — see the test below.
    var bare = std.mem.tokenizeAny(u8, "", " \t");
    try std.testing.expectEqual(@as(u8, default_depth), parseLimits(&bare, .white).depth);

    // `infinite` is the one that genuinely means "no ceiling".
    var forever = std.mem.tokenizeAny(u8, "infinite", " \t");
    const unlimited = parseLimits(&forever, .white);
    try std.testing.expectEqual(@as(u8, search.max_ply), unlimited.depth);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), unlimited.nodes);
    try std.testing.expectEqual(@as(?u64, null), unlimited.movetime_ms);
    try std.testing.expectEqual(@as(?search.Clock, null), unlimited.clock);
}

test "the clock a go carries is read for the side actually to move" {
    // One token stream, two sides, two answers. Reading the wrong colour's
    // clock is invisible in a symmetric time control and loses games in every
    // other one, so this is checked rather than assumed.
    const text = "wtime 60000 btime 30000 winc 600 binc 300";

    var white = std.mem.tokenizeAny(u8, text, " \t");
    const w = parseLimits(&white, .white).clock.?;
    try std.testing.expectEqual(@as(u64, 60000), w.remaining_ms);
    try std.testing.expectEqual(@as(u64, 600), w.increment_ms);

    var black = std.mem.tokenizeAny(u8, text, " \t");
    const b = parseLimits(&black, .black).clock.?;
    try std.testing.expectEqual(@as(u64, 30000), b.remaining_ms);
    try std.testing.expectEqual(@as(u64, 300), b.increment_ms);
}

test "a clock-only go is bounded by the clock, not by default_depth" {
    // The assertion that would have caught the bug this branch exists to fix:
    // koji parsed the clock, discarded it, and searched `default_depth` at every
    // time control. Two such binaries are the same player, which is why the
    // transposition table merged with no Elo number (docs/testlog.md).
    var clock = std.mem.tokenizeAny(u8, "wtime 60000 btime 60000 winc 600 binc 600", " \t");
    const limits = parseLimits(&clock, .white);
    try std.testing.expectEqual(@as(u8, search.max_ply), limits.depth);
    try std.testing.expect(limits.clock != null);

    // An increment is optional; a clock without one still binds.
    var no_inc = std.mem.tokenizeAny(u8, "wtime 60000 btime 60000", " \t");
    const bare_clock = parseLimits(&no_inc, .white).clock.?;
    try std.testing.expectEqual(@as(u64, 60000), bare_clock.remaining_ms);
    try std.testing.expectEqual(@as(u64, 0), bare_clock.increment_ms);
    try std.testing.expectEqual(@as(?u32, null), bare_clock.movestogo);

    // `movestogo` passes through untouched — the budget decides what to do with
    // it, and a GUI that names one means it.
    var repeating = std.mem.tokenizeAny(u8, "wtime 60000 btime 60000 movestogo 12", " \t");
    try std.testing.expectEqual(@as(?u32, 12), parseLimits(&repeating, .white).clock.?.movestogo);

    // The clock is one ceiling among several, not an override: a `go` naming
    // both still honours the tighter depth.
    var with_depth = std.mem.tokenizeAny(u8, "wtime 60000 depth 4", " \t");
    const both = parseLimits(&with_depth, .white);
    try std.testing.expectEqual(@as(u8, 4), both.depth);
    try std.testing.expect(both.clock != null);
}
