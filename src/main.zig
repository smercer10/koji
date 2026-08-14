//! koji — CLI entry point.
//!
//! The engine binary is also the project's tooling: `bench`, `perft` and `epd` are
//! subcommands rather than scripts, so they can never drift out of sync with the
//! engine they measure. This is also what OpenBench expects.
//!
//! Everything below Phase 0 is a stub that prints a well-formed placeholder. The
//! output *shapes* are contracts (OpenBench parses `bench`, GUIs parse `uci`), so
//! they are correct from the first commit even though the numbers are not real yet.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const attacks = @import("attacks.zig");
const board = @import("board.zig");
const Board = board.Board;
const movegen = @import("movegen.zig");
const perft_mod = @import("perft.zig");

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
        try uciLoop(io, out);
    } else if (eql(command, "bench")) {
        try bench(out);
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

/// OpenBench parses the last `<nodes> nodes <nps> nps` line off stdout, and the
/// node count must be identical across runs *and across machines* — including
/// between an AVX2 and a non-AVX2 build. That is why every eval path has to stay
/// integer once NNUE lands: floating-point accumulation reorders with SIMD width.
fn bench(out: *Io.Writer) Io.Writer.Error!void {
    const nodes: u64 = 0;
    const nps: u64 = 0;
    try out.print("{d} nodes {d} nps\n", .{ nodes, nps });
}

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

fn uciLoop(io: Io, out: *Io.Writer) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const in = &stdin_file.interface;

    while (try in.takeDelimiter('\n')) |raw| {
        // Tolerate CRLF: some GUIs and most Windows pipes send it.
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        var it = std.mem.tokenizeAny(u8, line, " \t");
        const token = it.next() orelse continue;

        if (eql(token, "uci")) {
            try identify(out);
        } else if (eql(token, "isready")) {
            try out.writeAll("readyok\n");
        } else if (eql(token, "ucinewgame")) {
            // no state to clear yet
        } else if (eql(token, "position")) {
            // Phase 1: parse `startpos|fen <fen>` + `moves ...`
        } else if (eql(token, "go")) {
            // Phase 2: real search. A null move keeps the protocol well-formed.
            try out.writeAll("bestmove 0000\n");
        } else if (eql(token, "stop")) {
            try out.writeAll("bestmove 0000\n");
        } else if (eql(token, "setoption")) {
            // Phase 2: apply Hash/Threads
        } else if (eql(token, "quit")) {
            try out.flush();
            return;
        }
        // Unknown commands are ignored, per the UCI spec.

        try out.flush();
    }
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
}

test "bench output matches the OpenBench contract" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try bench(&w);

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
