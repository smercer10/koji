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

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) args[1] else "uci";
    const rest = if (args.len > 2) args[2..] else &.{};

    if (eql(command, "uci")) {
        try uciLoop(io, out);
    } else if (eql(command, "bench")) {
        try bench(out);
    } else if (eql(command, "perft")) {
        try perftCommand(out, rest);
    } else if (eql(command, "epd")) {
        try epdCommand(out, rest);
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
        \\  uci             speak UCI on stdin/stdout (default)
        \\  bench           fixed benchmark; prints "<nodes> nodes <nps> nps"
        \\  perft <depth>   node count from the start position
        \\  epd <file>      run an EPD suite
        \\  version         print the version
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

fn perftCommand(out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) {
        try out.writeAll("usage: koji perft <depth> [fen]\n");
        try out.flush();
        return error.MissingArgument;
    }
    const depth = std.fmt.parseInt(u8, args[0], 10) catch {
        try out.print("perft: invalid depth: {s}\n", .{args[0]});
        try out.flush();
        return error.InvalidArgument;
    };
    try out.print("{d} nodes\n", .{perft(depth)});
}

/// Phase 1 replaces this with real make/unmake move generation. The signature is
/// the contract: a node count for a depth, nothing else.
fn perft(depth: u8) u64 {
    _ = depth;
    return 0;
}

// --- epd ---------------------------------------------------------------------

fn epdCommand(out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) {
        try out.writeAll("usage: koji epd <file>\n");
        try out.flush();
        return error.MissingArgument;
    }
    try out.print("epd: not implemented ({s}: 0/0)\n", .{args[0]});
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

test "perft is well-formed at shallow depths" {
    // Phase 1 replaces this with the real start-position node counts
    // (20, 400, 8902, 197281, 4865609, 119060324).
    try std.testing.expectEqual(@as(u64, 0), perft(1));
}

test "deep perft" {
    if (!build_options.slow) return error.SkipZigTest;
    // Phase 1: depth >= 6 on all standard positions. Lives behind -Dslow so the
    // fast test step stays under the few seconds that make it worth gating on.
    try std.testing.expectEqual(@as(u64, 0), perft(6));
}
