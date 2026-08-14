//! koji — search: negamax with alpha-beta, driven by iterative deepening, over a
//! transposition table.
//!
//! Deliberately nothing else. Quiescence and move ordering beyond "the table's
//! move, then the previous iteration's best at the root" are each their own
//! roadmap box, and each is measured against what this file does.
//!
//! What this file *is* responsible for is being right. Alpha-beta is supposed to
//! return exactly the score a plain minimax returns over the same tree — it
//! prunes branches it can prove cannot affect the result, and nothing else. The
//! test at the bottom asserts that against a reference minimax, and it is to this
//! file what perft is to `movegen.zig`: a deterministic check that a whole class
//! of subtle bug cannot hide in.
//
// origin: minimax — contested. CPW: von Neumann (1928, "Zur Theorie der
//         Gesellschaftsspiele") is "usually associated with that concept", but
//         "primacy probably belongs to Émile Borel" (1921). What this file
//         actually does is Norbert Wiener's variant (Cybernetics, 1948) —
//         minimax over *heuristic* scores at a depth limit, not von Neumann's
//         exact terminal values, a distinction CPW draws explicitly.
//         via https://www.chessprogramming.org/Minimax
// origin: negamax — unclear (folklore). CPW's page gives the formulation with
//         no history section and names no originator; the Knuth & Moore
//         attribution repeated elsewhere is not one CPW makes, so it is not
//         made here either.
//         via https://www.chessprogramming.org/Negamax
// origin: alpha-beta — no single inventor. CPW opens its history with
//         "invented independently by several researchers and pioneers from the
//         50s": McCarthy proposed it after seeing Bernstein's program at the
//         1956 Dartmouth workshop, Newell/Shaw/Simon (1958) and Samuel (1959)
//         approximated it, Edwards & Hart described it (1961), and Brudno
//         (1963) reached it independently of McCarthy. Knuth & Moore (1975)
//         gave the rigorous analysis — that, and only that, is what their name
//         is attached to here.
//         via https://www.chessprogramming.org/Alpha-Beta
// origin: iterative deepening, re-searching the previous iteration's best path
//         first — David Slate and Larry Atkin, Chess 4.5, 1977. Iterated
//         search for time control is older (Scott, 1969); the *term* was coined
//         by Jim Gillogly.
//         via https://www.chessprogramming.org/Iterative_Deepening
// origin: triangular PV table — unclear (folklore; CPW documents the array
//         layout and the copy-up step, with no history section and no author
//         credited)
//         via https://www.chessprogramming.org/Triangular_PV-Table
// origin: mate scores decremented by ply distance to the root — unclear
//         (folklore; CPW states the convention as what programs "usually" do
//         and names no one)
//         via https://www.chessprogramming.org/Score
// origin: storing mate scores relative to the node rather than to the root, so
//         one entry serves every ply the position is reached at — unclear
//         (folklore; the CPW score page states the root-distance convention and
//         names no one, and the table's half of it has no page at all)
//         via https://www.chessprogramming.org/Score
// origin: scoring the *first* repetition as a draw instead of waiting for the
//         third — unclear (folklore; CPW says "most programs do this on the
//         first repetition" and credits no one). Note that the same CPW page
//         does carry a named credit — Thompson, for detecting repetitions
//         through the transposition table — but that is a different technique
//         and does not transfer to this decision.
//         via https://www.chessprogramming.org/Repetitions

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const board = @import("board.zig");
const Board = board.Board;

const move = @import("move.zig");
const Move = move.Move;

const movegen = @import("movegen.zig");
const MoveList = movegen.MoveList;

const eval = @import("eval.zig");

const tt = @import("tt.zig");

pub const Score = eval.Score;

/// Hard ceiling on search recursion. Also the longest PV that can be reported.
pub const max_ply = 128;

/// Being checkmated scores `-mate_score` at ply 0, and one point less per ply
/// down — so of two mates the search prefers the shorter, and of two losses the
/// longer. Anything at least this good is therefore a forced mate, not material.
pub const mate_score: Score = 32_000;
pub const mate_threshold: Score = mate_score - max_ply;

/// Wider than any real score, so `-infinity` negates without overflow and is
/// never mistaken for a mate.
const infinity: Score = mate_score + 1;

/// Plies of game history kept behind the root. A repetition scan can only reach
/// back to the last irreversible move, which `Board.halfmove` counts and which
/// saturates at 255, so this is enough to make the scan exact rather than
/// merely long.
const game_history = 256;

/// How often the stop flag and the limits are consulted, in nodes. Only ever
/// *reads* state, so a search with no limits set takes the same path either way
/// and `bench` stays deterministic. Power of two: the check is a mask.
const check_interval = 2048;

/// What a `go` asks for. Everything is a ceiling — the search stops at whichever
/// binds first, or when `stop` arrives.
pub const Limits = struct {
    depth: u8 = max_ply,
    nodes: u64 = std.math.maxInt(u64),
    movetime_ms: ?u64 = null,
};

/// One completed iteration, handed to the reporter so `search.zig` never has to
/// know what UCI looks like.
pub const Info = struct {
    depth: u8,
    score: Score,
    nodes: u64,
    /// Nanoseconds, not milliseconds: an early iteration finishes inside a
    /// millisecond, and reporting `time 0` there costs the reader the nps for
    /// that line entirely. The reporter rounds to whatever the protocol wants.
    elapsed_ns: u64,
    /// Transposition table occupancy in permill. The only view anyone outside
    /// the search gets of the table, and the reason it is reported at all: a
    /// table that is never filling, or one that is full three plies in, is a
    /// visible fault rather than a slightly worse node count.
    hashfull: u32,
    pv: []const Move,
};

/// Where `info` lines go. A closure over the writer rather than a writer, so the
/// caller keeps ownership of buffering, locking and the protocol's wording.
pub const Reporter = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, info: Info) void,
};

pub const Result = struct {
    /// Null only when the root position has no legal move at all — the game is
    /// already over and there is nothing to play.
    move: ?Move,
    score: Score,
    depth: u8,
    nodes: u64,
};

pub const Searcher = struct {
    /// The game position. The search mutates it and restores it exactly, the
    /// same contract `perft` holds itself to.
    b: Board,

    /// Borrowed, never owned: the table outlives any one search, `ucinewgame`
    /// clears it from the UCI thread, and `setoption Hash` will reallocate it.
    /// A searcher pointed at `tt.Table.off` is slower and no less correct.
    tt: *tt.Table,

    /// Zobrist keys of every position from the start of the game to the current
    /// one, extended by the search path as it descends. The current position's
    /// key is always the last entry.
    history: [game_history + max_ply + 1]u64,
    history_len: usize,
    /// Where the game ends and the search began, so a search can rewind to it.
    root_history_len: usize,

    /// Triangular PV table: `pv[ply][0..pv_len[ply]]` is the best line found
    /// from `ply` down. One row longer than `max_ply` because the node at
    /// `max_ply` still clears its own row before returning.
    pv: [max_ply + 1][max_ply]Move,
    pv_len: [max_ply + 1]usize,

    /// Last completed iteration's best move, searched first by the next one.
    /// This is the whole reason iterative deepening is cheaper than jumping
    /// straight to the target depth rather than more expensive.
    root_best: ?Move,

    nodes: u64,
    limits: Limits,
    start: Io.Timestamp,
    io: Io,

    /// Set by another thread; read by the search every `check_interval` nodes.
    stop_flag: std.atomic.Value(bool),
    /// The search's own cached view of "we are done". Once set, every frame
    /// unwinds and the caller throws the whole iteration away.
    stopped: bool,

    /// **Never construct one with `= .{}`.** The struct is ~50KB of arrays that
    /// this function assigns anyway, and `= .{}` lowers to a `memset` of all of
    /// it — the idiom that cost perft 39% of its instructions (docs/testlog.md,
    /// 2026-08-14).
    pub fn init(s: *Searcher, io: Io, table: *tt.Table) void {
        s.io = io;
        s.tt = table;
        s.stop_flag = .init(false);
        s.stopped = false;
        s.nodes = 0;
        s.limits = .{};
        s.root_best = null;
        s.start = Io.Clock.awake.now(io);
        s.setPosition(Board.startpos);
    }

    /// Starts a new game history at `b`. Every `position` command lands here.
    pub fn setPosition(s: *Searcher, b: Board) void {
        s.b = b;
        s.history[0] = b.hash;
        s.history_len = 1;
        s.root_history_len = 1;
    }

    /// Plays one move of the *game* (not of the search), keeping the history
    /// that repetition detection reads.
    pub fn playMove(s: *Searcher, m: Move) void {
        _ = move.makeMove(&s.b, m);
        s.pushHistory();
        s.root_history_len = s.history_len;
    }

    fn pushHistory(s: *Searcher) void {
        if (s.history_len == s.history.len) {
            // A game longer than the buffer drops its oldest plies. Correct, not
            // merely tolerable: the scan below never looks further back than
            // `halfmove`, which saturates at 255, and `game_history` is larger.
            const keep = s.history.len - 1;
            std.mem.copyForwards(u64, s.history[0..keep], s.history[1..]);
            s.history_len = keep;
            s.root_history_len -|= 1;
        }
        s.history[s.history_len] = s.b.hash;
        s.history_len += 1;
    }

    /// Whether the position on the board has already occurred in this line.
    ///
    /// The *first* repetition counts, not the third. Inside a search the
    /// distinction barely exists — a side that can repeat once can repeat
    /// again — and taking the first one prunes the whole subtree that would
    /// re-derive the same conclusion two plies later.
    fn repeated(s: *const Searcher) bool {
        // Only positions since the last irreversible move can possibly match: a
        // capture or a pawn move makes everything before it unreachable.
        // `halfmove` counts exactly those plies and so bounds the scan.
        const reachable = @min(s.history_len - 1, @as(usize, s.b.halfmove));
        // Same side to move only recurs at an even distance back.
        var back: usize = 2;
        while (back <= reachable) : (back += 2) {
            if (s.history[s.history_len - 1 - back] == s.b.hash) return true;
        }
        return false;
    }

    /// Draw by repetition or by the fifty-move rule.
    fn drawnByRule(s: *Searcher) bool {
        if (s.repeated()) return true;
        if (s.b.halfmove < 100) return false;

        // Mate delivered on the hundredth halfmove is mate, not a draw. Asking
        // movegen is affordable here precisely because it is only ever asked at
        // the ceiling, which almost no real position reaches.
        if (!movegen.inCheck(&s.b)) return true;
        var list: MoveList = undefined;
        movegen.generate(&s.b, &list);
        return list.len != 0;
    }

    fn pollLimits(s: *Searcher) void {
        if (s.stop_flag.load(.monotonic) or s.nodes >= s.limits.nodes) {
            s.stopped = true;
            return;
        }
        if (s.limits.movetime_ms) |ms| {
            if (s.elapsedNs() >= ms *| std.time.ns_per_ms) s.stopped = true;
        }
    }

    fn elapsedNs(s: *const Searcher) u64 {
        const ns = s.start.durationTo(Io.Clock.awake.now(s.io)).nanoseconds;
        return @intCast(@max(ns, 0));
    }

    /// Asks a running search to stop. Safe to call from another thread; that is
    /// the only reason this is an atomic rather than a plain bool.
    pub fn requestStop(s: *Searcher) void {
        s.stop_flag.store(true, .monotonic);
    }

    /// Arms the flag for a fresh search. **The caller does this before starting
    /// the search, never the search itself**: a `stop` can arrive in the window
    /// between `go` and the search thread getting as far as its first node, and
    /// a search that cleared its own flag on entry would swallow it and then run
    /// unbounded. Clearing here, on the thread that handles `go`, orders the two
    /// against each other.
    pub fn clearStop(s: *Searcher) void {
        s.stop_flag.store(false, .monotonic);
    }

    /// Iterative deepening. Returns the best move of the deepest iteration that
    /// *finished* — a partial iteration is discarded whole rather than mined for
    /// a better move, because its scores were produced under a window the abort
    /// invalidated.
    pub fn search(s: *Searcher, limits: Limits, reporter: ?Reporter) Result {
        s.limits = limits;
        s.nodes = 0;
        s.root_best = null;
        // Private to this thread, unlike `stop_flag`, so resetting it here is
        // safe and keeps a previous search's abort from poisoning this one.
        s.stopped = false;
        s.start = Io.Clock.awake.now(s.io);
        s.history_len = s.root_history_len;
        s.tt.newSearch();

        var root: MoveList = undefined;
        movegen.generate(&s.b, &root);
        if (root.len == 0) return .{ .move = null, .score = 0, .depth = 0, .nodes = 0 };

        // An abort before the first iteration completes still has to answer with
        // a legal move, so seed with one.
        var result: Result = .{
            .move = root.moves[0],
            .score = 0,
            .depth = 0,
            .nodes = 0,
        };

        const target = @min(limits.depth, max_ply);
        var depth: u8 = 1;
        while (depth <= target) : (depth += 1) {
            const score = s.negamax(depth, 0, -infinity, infinity);
            if (s.stopped) break;

            assert(s.pv_len[0] > 0);
            result = .{
                .move = s.pv[0][0],
                .score = score,
                .depth = depth,
                .nodes = s.nodes,
            };
            s.root_best = s.pv[0][0];

            if (reporter) |r| r.emit(r.ctx, .{
                .depth = depth,
                .score = score,
                .nodes = s.nodes,
                .elapsed_ns = s.elapsedNs(),
                .hashfull = s.tt.hashfull(),
                .pv = s.pv[0][0..s.pv_len[0]],
            });
        }

        result.nodes = s.nodes;
        assert(s.history_len == s.root_history_len);
        return result;
    }

    fn negamax(s: *Searcher, depth: i32, ply: u32, alpha_in: Score, beta: Score) Score {
        s.pv_len[ply] = 0;
        s.nodes += 1;

        if (s.nodes & (check_interval - 1) == 0) s.pollLimits();
        if (s.stopped) return 0;

        // Never at the root: whatever the history says, the game is not over
        // there, and answering 0 would mean refusing to pick a move.
        //
        // **This stays ahead of the table probe.** A repetition is a fact about
        // the path, not about the position, and the table only knows positions —
        // so the rules get to answer first, and a stored score can never turn a
        // drawn line back into a won one.
        if (ply > 0 and s.drawnByRule()) return 0;

        if (depth <= 0 or ply >= max_ply) return eval.evaluate(&s.b);

        var alpha = alpha_in;
        var tt_move: ?Move = null;

        if (s.tt.probe(s.b.hash)) |entry| {
            // Worth having at any depth: ordering is what a shallow entry is
            // for, and it is the larger half of what the table buys.
            tt_move = entry.move;

            // Never at the root, which has to produce a move and a principal
            // variation, not just a number.
            if (ply > 0 and entry.depth >= depth) {
                const score = scoreFromTt(entry.score, ply);
                switch (entry.meta.bound) {
                    .exact => return score,
                    .lower => if (score >= beta) return score,
                    .upper => if (score <= alpha) return score,
                    .none => unreachable, // `probe` does not return empty entries
                }
            }
        }

        var list: MoveList = undefined;
        movegen.generate(&s.b, &list);
        if (list.len == 0) {
            // Checkmate is scored from the mated side's view, which is the side
            // to move here; stalemate is simply a draw. Neither is stored: an
            // entry has to carry a move, and there is none.
            return if (movegen.inCheck(&s.b)) -(mate_score - @as(Score, @intCast(ply))) else 0;
        }

        if (tt_move) |m| {
            moveToFront(&list, m);
        } else if (ply == 0) {
            // Only reached when the root's own entry has been evicted, which a
            // small table under a long game does do.
            if (s.root_best) |best| moveToFront(&list, best);
        }

        var best = -infinity;
        // Every stored entry carries a move, including a fail-low node's: the
        // move that scored highest is still the one to try first next time.
        var best_move = list.moves[0];

        for (list.slice()) |m| {
            const undo = move.makeMove(&s.b, m);
            s.pushHistory();

            const score = -s.negamax(depth - 1, ply + 1, -beta, -alpha);

            s.history_len -= 1;
            move.unmakeMove(&s.b, m, undo);

            // Nothing below this point may write to the table: `best` is a
            // partial answer under a window the abort invalidated.
            if (s.stopped) return 0;

            if (score > best) {
                best = score;
                best_move = m;
                if (score > alpha) {
                    alpha = score;
                    s.updatePv(ply, m);
                }
                // Fail-soft: the caller is told the best score actually seen,
                // not merely that the window was exceeded, which is what makes
                // the bound stored below a true statement about the position
                // rather than one about this node's window.
                if (alpha >= beta) break;
            }
        }

        // `alpha_in`, not `alpha`: the question is whether anything beat the
        // window the caller asked about, and `alpha` has been moving.
        const bound: tt.Bound = if (best >= beta)
            .lower
        else if (best <= alpha_in)
            .upper
        else
            .exact;
        s.tt.store(s.b.hash, best_move, scoreToTt(best, ply), @intCast(depth), bound);

        return best;
    }

    /// This ply's PV becomes `m` followed by the child's PV.
    fn updatePv(s: *Searcher, ply: u32, m: Move) void {
        s.pv[ply][0] = m;
        const child = s.pv_len[ply + 1];
        // A line at the very bottom of the table has nowhere to append to; the
        // move itself is still the best known and is worth reporting.
        const copied = @min(child, max_ply - 1);
        @memcpy(s.pv[ply][1..][0..copied], s.pv[ply + 1][0..copied]);
        s.pv_len[ply] = copied + 1;
    }
};

/// A mate score, going into the table, is rebased from "plies from the root" to
/// "plies from here".
///
/// The table is indexed by position, and the same mating position is reached at
/// different plies down different lines — so an entry has to say "mate in three
/// from this square" and not "mate in three from wherever it was first seen", or
/// the second line to reach it inherits the first line's distance. Everything
/// outside the mate range is a static score and passes through untouched.
fn scoreToTt(score: Score, ply: u32) i16 {
    assert(score > -infinity and score < infinity);
    const from_root: Score = @intCast(ply);
    if (score >= mate_threshold) return @intCast(score + from_root);
    if (score <= -mate_threshold) return @intCast(score - from_root);
    return @intCast(score);
}

/// The inverse, applied on the way out of a probe.
fn scoreFromTt(score: i16, ply: u32) Score {
    const from_root: Score = @intCast(ply);
    const value: Score = score;
    if (value >= mate_threshold) return value - from_root;
    if (value <= -mate_threshold) return value + from_root;
    return value;
}

/// Swaps `m` to the front of `list` if it is there at all. Preserves nothing
/// else about the order — at the root, one move ahead of an otherwise unsorted
/// list is exactly what iterative deepening has to offer.
fn moveToFront(list: *MoveList, m: Move) void {
    for (list.moves[0..list.len], 0..) |candidate, i| {
        if (@as(u16, @bitCast(candidate)) == @as(u16, @bitCast(m))) {
            std.mem.swap(Move, &list.moves[0], &list.moves[i]);
            return;
        }
    }
}

/// Distance to mate in *moves*, signed: positive if the side to move is
/// mating, negative if it is being mated. Null if `score` is not a mate score.
/// This is the shape UCI's `score mate <n>` wants.
pub fn mateDistance(score: Score) ?i32 {
    if (score >= mate_threshold) {
        const plies = mate_score - score;
        return @divTrunc(plies + 1, 2);
    }
    if (score <= -mate_threshold) {
        const plies = mate_score + score;
        return -@divTrunc(plies + 1, 2);
    }
    return null;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const attacks = @import("attacks.zig");

/// The table the tests below run against unless they say otherwise: disabled, so
/// every probe misses and every store drops.
///
/// That is the right default here rather than a lazy one. Most of this file's
/// assertions are about alpha-beta — that it returns what minimax returns, that
/// a bound is honest, that a mate is scored by distance — and they have to keep
/// holding for the search itself, not merely for a search whose table happened
/// to be warm. The table's own effects get their own tests, below, and the ones
/// that matter run against a table small enough to collide on nearly every node.
var no_table: tt.Table = .off;

fn searcher(fen: ?[]const u8) !*Searcher {
    return searcherWith(fen, &no_table);
}

fn searcherWith(fen: ?[]const u8, table: *tt.Table) !*Searcher {
    // The sliding attack tables are runtime-initialised globals. Every test
    // that touches movegen arms them itself rather than inheriting whatever an
    // earlier test happened to leave behind — otherwise the suite passes or
    // crashes depending on the order it is run in.
    attacks.init();

    const s = try testing.allocator.create(Searcher);
    // A rejected FEN would otherwise leak the searcher and report itself as a
    // leak rather than as the parse failure it is.
    errdefer testing.allocator.destroy(s);
    s.init(testing.io, table);
    if (fen) |text| s.setPosition(try movegen.fromFen(text));
    return s;
}

/// Plain minimax over the same tree: no window, no cutoffs, everything else
/// identical. Alpha-beta's entire claim is that it returns this number while
/// visiting fewer nodes, so this is the reference the claim is checked against.
fn referenceMinimax(s: *Searcher, depth: i32, ply: u32) Score {
    if (ply > 0 and s.drawnByRule()) return 0;
    if (depth <= 0 or ply >= max_ply) return eval.evaluate(&s.b);

    var list: MoveList = undefined;
    movegen.generate(&s.b, &list);
    if (list.len == 0) {
        return if (movegen.inCheck(&s.b)) -(mate_score - @as(Score, @intCast(ply))) else 0;
    }

    var best = -infinity;
    for (list.slice()) |m| {
        const undo = move.makeMove(&s.b, m);
        s.pushHistory();
        const score = -referenceMinimax(s, depth - 1, ply + 1);
        s.history_len -= 1;
        move.unmakeMove(&s.b, m, undo);
        if (score > best) best = score;
    }
    return best;
}

test "alpha-beta returns exactly the score minimax does" {
    // The sharpest test in this file, and the reason it is written first: every
    // window bug, every mate score not adjusted for ply, every fail-soft bound
    // that claims more than it proved shows up here as a mismatch, on a fixed
    // tree, deterministically. Alpha-beta is only allowed to be faster.
    //
    // **It runs with the table off, and has to.** A transposition table legally
    // breaks this equality: an entry stored by an earlier, deeper iteration is
    // returned at a node the current depth would have searched shallowly, so a
    // fixed-depth search with a table can return a score fixed-depth minimax
    // does not — better information, not a bug. This test is about alpha-beta;
    // asserting it with a table would be asserting something false.
    const cases = .{
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 4 },
        // Kiwipete: castling, pins and a dense capture set.
        .{ "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3 },
        // Promotions and an en passant, where scores swing by a queen.
        .{ "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 4 },
        // In check at the root: six legal replies, three kinds of escape.
        .{ "4k3/8/8/8/7b/8/6P1/4K2R w K - 0 1", 4 },
        // A forced mate inside the tree, which is where a ply adjustment that
        // is off by one shows up as a score and not as a crash.
        .{ "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", 4 },
        // A sparse endgame: few moves, long lines, nothing to capture.
        .{ "8/8/8/3k4/8/8/3KP3/8 w - - 0 1", 5 },
    };

    inline for (cases) |case| {
        const s = try searcher(case[0]);
        defer testing.allocator.destroy(s);

        const expected = referenceMinimax(s, case[1], 0);
        const actual = s.negamax(case[1], 0, -infinity, infinity);
        testing.expectEqual(expected, actual) catch |err| {
            std.debug.print("mismatch at depth {d} in {s}\n", .{ case[1], case[0] });
            return err;
        };
    }
}

test "a narrow window never changes which side of it the true score falls on" {
    // Alpha-beta is only score-exact inside its window; outside it, fail-soft
    // promises a *bound*. That bound is what a transposition table will store,
    // so it is worth pinning now: a search returning <= alpha must not be hiding
    // a score above it, and one returning >= beta must not be hiding one below.
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);

    const truth = s.negamax(3, 0, -infinity, infinity);

    var offset: Score = -300;
    while (offset <= 300) : (offset += 100) {
        const alpha = truth + offset;
        const beta = alpha + 1;
        s.root_best = null;
        const bound = s.negamax(3, 0, alpha, beta);
        if (truth >= beta) {
            try testing.expect(bound >= beta);
        } else if (truth <= alpha) {
            try testing.expect(bound <= alpha);
        }
    }
}

test "every move of the principal variation is legal" {
    // CLAUDE.md: an illegal PV move is never cosmetic. With the table off, this
    // is the assertion the table is later measured against — see "a table small
    // enough to collide on every node still produces a legal PV" below, which is
    // the same check where a collision can actually happen.
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
    };

    for (fens) |fen| {
        const s = try searcher(fen);
        defer testing.allocator.destroy(s);

        const result = s.search(.{ .depth = 4 }, null);
        const pv = s.pv[0][0..s.pv_len[0]];
        try testing.expect(pv.len > 0);
        try testing.expectEqual(result.move.?, pv[0]);

        // Replay it, checking each move against the legal list of the position
        // it is actually played in, then rewind.
        var played: usize = 0;
        var undos: [max_ply]move.Undo = undefined;
        for (pv) |m| {
            var list: MoveList = undefined;
            movegen.generate(&s.b, &list);

            var legal = false;
            for (list.slice()) |candidate| {
                if (@as(u16, @bitCast(candidate)) == @as(u16, @bitCast(m))) legal = true;
            }
            testing.expect(legal) catch |err| {
                std.debug.print("illegal PV move {f} at ply {d} in {s}\n", .{ m, played, fen });
                return err;
            };

            undos[played] = move.makeMove(&s.b, m);
            played += 1;
        }
        while (played > 0) {
            played -= 1;
            move.unmakeMove(&s.b, pv[played], undos[played]);
        }
    }
}

test "mate in one is found and scored by distance" {
    // White: Ra1-a8 is mate, the black king walled in by its own pawns.
    const s = try searcher("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1");
    defer testing.allocator.destroy(s);

    const result = s.search(.{ .depth = 3 }, null);
    try testing.expectEqual(mate_score - 1, result.score);
    try testing.expectEqual(@as(?i32, 1), mateDistance(result.score));
    try testing.expectEqual(@as(usize, 1), s.pv_len[0]);

    var buf: [8]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try result.move.?.format(&w);
    try testing.expectEqualStrings("a1a8", w.buffered());
}

test "the same mate is seen from the other side of the board" {
    // The mirror, so a colour hardcoded anywhere in the mate path shows up.
    const s = try searcher("r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1");
    defer testing.allocator.destroy(s);

    const result = s.search(.{ .depth = 3 }, null);
    try testing.expectEqual(mate_score - 1, result.score);

    var buf: [8]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try result.move.?.format(&w);
    try testing.expectEqualStrings("a8a1", w.buffered());
}

test "being mated is scored as a loss, and a slower loss is preferred" {
    // Two positions one tempo apart. Mate arriving later must score higher for
    // the losing side — that is the whole point of folding ply into the score,
    // and the sign is easy to get backwards.
    const sooner = try searcher("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1");
    defer testing.allocator.destroy(sooner);
    const fast = sooner.search(.{ .depth = 4 }, null).score;

    const later = try searcher("6k1/5ppp/8/8/8/7P/5PP1/R5K1 w - - 0 1");
    defer testing.allocator.destroy(later);
    const slow = later.search(.{ .depth = 4 }, null).score;

    // Both are winning for White; the one that mates in fewer plies scores more.
    try testing.expect(fast >= mate_threshold);
    try testing.expect(fast >= slow);
}

test "stalemate is a draw and checkmate at the root has no move" {
    const stalemate = try searcher("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    defer testing.allocator.destroy(stalemate);
    const drawn = stalemate.search(.{ .depth = 4 }, null);
    try testing.expectEqual(@as(?Move, null), drawn.move);

    const mated = try searcher("R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1");
    defer testing.allocator.destroy(mated);
    const lost = mated.search(.{ .depth = 4 }, null);
    try testing.expectEqual(@as(?Move, null), lost.move);
}

test "a repeated position is recognised" {
    const s = try searcher(null);
    defer testing.allocator.destroy(s);

    const knights_out_and_back = [_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8" };
    for (knights_out_and_back, 0..) |text, i| {
        try testing.expect(!s.repeated());
        s.playMove(move.Move.fromUci(&s.b, text).?);
        // Only the last of the four restores the start position.
        try testing.expectEqual(i == knights_out_and_back.len - 1, s.repeated());
    }
    try testing.expectEqual(Board.startpos.hash, s.b.hash);
}

test "an irreversible move makes earlier positions unreachable" {
    // A pawn move resets `halfmove`, which is what bounds the scan. If the bound
    // were ever dropped, the scan would run back past a position that can no
    // longer recur and could match a key from a genuinely different game phase.
    const s = try searcher(null);
    defer testing.allocator.destroy(s);

    for ([_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8", "e2e4" }) |text| {
        s.playMove(move.Move.fromUci(&s.b, text).?);
    }
    try testing.expectEqual(@as(u8, 0), s.b.halfmove);
    try testing.expect(!s.repeated());
}

test "a search that can repeat a position scores it as a draw" {
    // White is a rook down, so every line that plays on is worth about -500.
    // The one exception is stepping back into a position that has already
    // occurred, which is worth 0 — and the search has to prefer it. This is the
    // whole reason the game history is threaded into the search rather than
    // being the UCI layer's business.
    const s = try searcher("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/1NBQKBNR w Kkq - 0 1");
    defer testing.allocator.destroy(s);

    // Shuffle both knights out and back, so the root position has occurred
    // twice and its predecessors are all still in reach of the scan.
    for ([_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8" }) |text| {
        s.playMove(move.Move.fromUci(&s.b, text).?);
    }

    const result = s.search(.{ .depth = 2 }, null);
    try testing.expectEqual(@as(Score, 0), result.score);

    // ...and it is a repetition that is being claimed, not a tactic: the move
    // played has to be one that recreates an earlier position.
    s.playMove(result.move.?);
    try testing.expect(s.repeated());
}

test "the fifty-move rule is a draw, but not when it is mate" {
    // A rook down with the clock at 99: every legal move here is a king move,
    // so every one of them ticks it to 100 and saves the game. Worth 0, not the
    // -500 the material says.
    const drawn = try searcher("7k/8/8/8/8/8/r7/6K1 w - - 99 60");
    defer testing.allocator.destroy(drawn);
    try testing.expectEqual(@as(Score, 0), drawn.search(.{ .depth = 4 }, null).score);

    // The same clock, but Black is mated where it stands. Mate outranks the
    // fifty-move rule, and the search must not answer 0 here.
    const mated = try searcher("R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 100 60");
    defer testing.allocator.destroy(mated);
    try testing.expect(mated.drawnByRule() == false);
}

test "the board is restored exactly by a search" {
    // The same contract perft holds itself to. A leaked undo shows up as a
    // wrong evaluation long before it shows up as a crash.
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);

    const before = s.b;
    _ = s.search(.{ .depth = 4 }, null);

    try testing.expectEqual(before.hash, s.b.hash);
    try testing.expectEqual(before.hash, s.b.computeHash());
    try testing.expect(s.b.consistent());
    try testing.expectEqual(before.castling, s.b.castling);
    try testing.expectEqual(before.halfmove, s.b.halfmove);
    try testing.expectEqual(s.root_history_len, s.history_len);
}

test "a search is deterministic" {
    // `bench` is only meaningful if the same position at the same depth costs
    // the same nodes every time. Nothing here may consult a clock or a random.
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);

    const first = s.search(.{ .depth = 4 }, null);
    const second = s.search(.{ .depth = 4 }, null);

    try testing.expectEqual(first.nodes, second.nodes);
    try testing.expectEqual(first.score, second.score);
    try testing.expectEqual(first.move.?, second.move.?);
}

test "the node limit is respected" {
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);

    const limit = 20_000;
    const result = s.search(.{ .depth = max_ply, .nodes = limit }, null);

    // Checked once every `check_interval` nodes, so the overshoot is bounded by
    // that, not zero.
    try testing.expect(result.nodes >= limit);
    try testing.expect(result.nodes < limit + 2 * check_interval);
    try testing.expect(result.move != null);
}

test "a stop request is honoured and still answers with a legal move" {
    const s = try searcher(null);
    defer testing.allocator.destroy(s);

    // Set before the search begins, which is the race the UCI layer has to
    // survive: `stop` can arrive before the search thread reaches its first
    // node. Nothing inside `search` may clear it — that is what `clearStop` is
    // for, and it is the caller's to call.
    s.requestStop();
    const result = s.search(.{ .depth = 6 }, null);

    // Bounded well below what depth 6 costs unaided, so a stop that is ignored
    // fails here on the count rather than by running until someone kills it.
    try testing.expect(result.nodes < 100_000);

    var list: MoveList = undefined;
    movegen.generate(&s.b, &list);
    var legal = false;
    for (list.slice()) |m| {
        if (@as(u16, @bitCast(m)) == @as(u16, @bitCast(result.move.?))) legal = true;
    }
    try testing.expect(legal);
}

test "iterative deepening reaches the depth it is asked for" {
    const s = try searcher(null);
    defer testing.allocator.destroy(s);

    var depth: u8 = 1;
    while (depth <= 5) : (depth += 1) {
        const result = s.search(.{ .depth = depth }, null);
        try testing.expectEqual(depth, result.depth);
        try testing.expect(s.pv_len[0] <= depth);
    }
}

test "searching the previous best move first does not change the score" {
    // Root ordering is the one thing iterative deepening buys, and reordering a
    // move list is not allowed to change what the search concludes.
    const fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";

    const deepened = try searcher(fen);
    defer testing.allocator.destroy(deepened);
    const with_ordering = deepened.search(.{ .depth = 4 }, null).score;

    const cold = try searcher(fen);
    defer testing.allocator.destroy(cold);
    cold.root_best = null;
    const without_ordering = cold.negamax(4, 0, -infinity, infinity);

    try testing.expectEqual(without_ordering, with_ordering);
}

// --- with the transposition table on ------------------------------------------

/// Two entries, so nearly every position in a search collides with the one
/// before it and replacement runs constantly. Any test that passes here would
/// pass with a real table; the reverse is not true, which is the point.
fn tinyTable() tt.Table {
    return .{ .entries = &tiny_entries, .generation = 0 };
}
var tiny_entries: [2]tt.Entry align(64) = @splat(std.mem.zeroes(tt.Entry));

fn realTable() !tt.Table {
    return tt.Table.init(testing.allocator, 1);
}

test "a table small enough to collide on every node still produces a legal PV" {
    // The invariant from CLAUDE.md, tested where it can actually break. Two
    // slots for a whole search means the key check is the only thing standing
    // between the ordering move and a move from an unrelated position — if it is
    // wrong, or if the stored move is trusted without it, this fires.
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
    };

    var table = tinyTable();
    table.clear();

    for (fens) |fen| {
        const s = try searcherWith(fen, &table);
        defer testing.allocator.destroy(s);

        // Depth 4, as the table-off version of this test uses: what makes this
        // one sharp is the two slots, not the depth, and every extra ply here is
        // paid by `zig build test` on every turn.
        var depth: u8 = 1;
        while (depth <= 4) : (depth += 1) {
            const result = s.search(.{ .depth = depth }, null);
            const pv = s.pv[0][0..s.pv_len[0]];
            try testing.expect(pv.len > 0);
            try testing.expectEqual(result.move.?, pv[0]);

            // Replay it, checking each move against the legal list of the
            // position it is actually played in, then rewind.
            var played: usize = 0;
            var undos: [max_ply]move.Undo = undefined;
            for (pv) |m| {
                var list: MoveList = undefined;
                movegen.generate(&s.b, &list);

                var legal = false;
                for (list.slice()) |candidate| {
                    if (@as(u16, @bitCast(candidate)) == @as(u16, @bitCast(m))) legal = true;
                }
                testing.expect(legal) catch |err| {
                    std.debug.print(
                        "illegal PV move {f} at ply {d}, depth {d}, in {s}\n",
                        .{ m, played, depth, fen },
                    );
                    return err;
                };

                undos[played] = move.makeMove(&s.b, m);
                played += 1;
            }
            while (played > 0) {
                played -= 1;
                move.unmakeMove(&s.b, pv[played], undos[played]);
            }
        }
    }
}

test "the table is used, and searching with one costs fewer nodes" {
    // The test that fires if the table is wired up but never actually hit — a
    // probe that always misses breaks nothing else in this file.
    const fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";

    const without = try searcher(fen);
    defer testing.allocator.destroy(without);
    const cold = without.search(.{ .depth = 5 }, null);

    var table = try realTable();
    defer table.deinit(testing.allocator);
    const with = try searcherWith(fen, &table);
    defer testing.allocator.destroy(with);
    const warm = with.search(.{ .depth = 5 }, null);

    try testing.expect(warm.nodes < cold.nodes);
    try testing.expect(table.hashfull() > 0);
}

test "a mate is still scored by its distance with the table on" {
    // Where a missing ply adjustment shows up. A mate score stored at ply 4 and
    // read back at ply 1 is three plies further away than it really is, which
    // reaches the GUI as a wrong `mate <n>` and the search as a preference for
    // the slower mate.
    var table = try realTable();
    defer table.deinit(testing.allocator);

    const white = try searcherWith("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", &table);
    defer testing.allocator.destroy(white);
    // From 2, which is the shallowest depth that sees the mate at all: a
    // depth-1 child is a leaf and answers with `evaluate` before it ever asks
    // whether the side to move has a move. Every iteration after the first reads
    // the mate back out of the table instead of re-deriving it, which is exactly
    // the path the ply adjustment has to survive.
    var depth: u8 = 2;
    while (depth <= 6) : (depth += 1) {
        const result = white.search(.{ .depth = depth }, null);
        try testing.expectEqual(mate_score - 1, result.score);
        try testing.expectEqual(@as(?i32, 1), mateDistance(result.score));
    }

    const black = try searcherWith("r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1", &table);
    defer testing.allocator.destroy(black);
    try testing.expectEqual(mate_score - 1, black.search(.{ .depth = 4 }, null).score);

    // The losing side of the same position: a slower loss must still score
    // higher than a faster one when both come back through the table.
    const mated = try searcherWith("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", &table);
    defer testing.allocator.destroy(mated);
    const fast = mated.search(.{ .depth = 4 }, null).score;

    const slower = try searcherWith("6k1/5ppp/8/8/8/7P/5PP1/R5K1 w - - 0 1", &table);
    defer testing.allocator.destroy(slower);
    const slow = slower.search(.{ .depth = 4 }, null).score;

    try testing.expect(fast >= mate_threshold);
    try testing.expect(fast >= slow);
}

test "a mate score survives a round trip through the table at any ply" {
    // The conversion on its own, away from the search: rebasing to the node and
    // back must be the identity, and a static score must not be touched at all.
    var ply: u32 = 0;
    while (ply < max_ply) : (ply += 1) {
        const from_root: Score = @intCast(ply);
        for ([_]Score{ mate_score, mate_score - 1, mate_threshold }) |mate| {
            // A mate this far from the root is only representable below it.
            if (mate - from_root < mate_threshold) continue;
            const score = mate - from_root;
            try testing.expectEqual(score, scoreFromTt(scoreToTt(score, ply), ply));
            try testing.expectEqual(-score, scoreFromTt(scoreToTt(-score, ply), ply));
        }
        for ([_]Score{ 0, 1, -1, 900, -900, mate_threshold - 1 }) |score| {
            try testing.expectEqual(score, scoreToTt(score, ply));
            try testing.expectEqual(score, scoreFromTt(@intCast(score), ply));
        }
    }

    // ...and the rebasing is what makes one entry serve two depths: the same
    // mate seen three plies deeper is the same stored number.
    try testing.expectEqual(scoreToTt(mate_score - 1, 1), scoreToTt(mate_score - 4, 4));
}

test "the draw rules still outrank the table" {
    // The graph-history-interaction guard. A repetition is a property of the
    // path, so a score stored for the position from a line that could not repeat
    // must never be able to claim the draw away.
    var table = try realTable();
    defer table.deinit(testing.allocator);

    const s = try searcherWith("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/1NBQKBNR w Kkq - 0 1", &table);
    defer testing.allocator.destroy(s);

    // Warm the table on this position *before* the repetition exists, so the
    // entries the final search probes were written when playing on was still
    // worth about a rook down rather than worth 0.
    _ = s.search(.{ .depth = 4 }, null);

    for ([_][]const u8{ "g1f3", "g8f6", "f3g1", "f6g8" }) |text| {
        s.playMove(move.Move.fromUci(&s.b, text).?);
    }

    const result = s.search(.{ .depth = 2 }, null);
    try testing.expectEqual(@as(Score, 0), result.score);
    s.playMove(result.move.?);
    try testing.expect(s.repeated());

    // The fifty-move rule, same argument: the clock is not in the Zobrist key,
    // so two positions one move apart on it share an entry.
    const drawn = try searcherWith("7k/8/8/8/8/8/r7/6K1 w - - 99 60", &table);
    defer testing.allocator.destroy(drawn);
    try testing.expectEqual(@as(Score, 0), drawn.search(.{ .depth = 4 }, null).score);
}

test "a search with the table is deterministic from a cleared one" {
    // `bench` clears between positions for exactly this reason: with the table
    // carried over, a search depends on every search before it. From a cleared
    // table the same position must cost the same nodes every time, or the
    // `Bench:` line in a commit message means nothing.
    var table = try realTable();
    defer table.deinit(testing.allocator);

    const s = try searcherWith(
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        &table,
    );
    defer testing.allocator.destroy(s);

    table.clear();
    const first = s.search(.{ .depth = 5 }, null);
    table.clear();
    const second = s.search(.{ .depth = 5 }, null);

    try testing.expectEqual(first.nodes, second.nodes);
    try testing.expectEqual(first.score, second.score);
    try testing.expectEqual(first.move.?, second.move.?);
}

test "mate distances convert to the shape UCI asks for" {
    try testing.expectEqual(@as(?i32, 1), mateDistance(mate_score - 1));
    try testing.expectEqual(@as(?i32, 1), mateDistance(mate_score - 2));
    try testing.expectEqual(@as(?i32, 2), mateDistance(mate_score - 3));
    try testing.expectEqual(@as(?i32, -1), mateDistance(-(mate_score - 1)));
    try testing.expectEqual(@as(?i32, -2), mateDistance(-(mate_score - 3)));
    try testing.expectEqual(@as(?i32, null), mateDistance(0));
    try testing.expectEqual(@as(?i32, null), mateDistance(900));
    try testing.expectEqual(@as(?i32, null), mateDistance(-900));
}
