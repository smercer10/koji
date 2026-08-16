//! koji — search: negamax with alpha-beta, driven by iterative deepening, over a
//! transposition table, ending in a quiescence search rather than at a static
//! score.
//!
//! Moves are ordered by MVV-LVA behind the table's move. Deliberately nothing
//! else: SEE, killers and history are their own roadmap boxes and are measured
//! against what this file does.
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

const see = @import("see.zig");

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

/// A move's share of the clock, in milliseconds.
///
/// Two limits rather than one. The basic published allocation is a single
/// number, and CPW presents the second bound as an enhancement on top of it —
/// but a lone deadline can only be checked inside the search, so it always
/// fires part-way through an iteration and throws that iteration's whole cost
/// away. The pair lets the search decline to start work it cannot finish, and
/// keeps the mid-flight abort for when it guessed wrong.
///
/// origin: unclear — folklore, no source names an originator
/// via https://www.chessprogramming.org/Time_Management
pub const Budget = struct {
    /// Checked between iterations: the deepening loop will not *start* another
    /// one past this.
    soft_ms: u64,
    /// Checked inside the search: abort wherever it has got to, and discard the
    /// partial iteration.
    hard_ms: u64,
};

/// The clock as UCI reports it, with the side to move already resolved. Turning
/// it into a budget is time management, so it happens here rather than in the
/// protocol layer that read the tokens.
pub const Clock = struct {
    remaining_ms: u64,
    increment_ms: u64 = 0,
    /// Moves until the next time control, when the GUI names one. UCI leaves it
    /// out at sudden death, which is most of them.
    movestogo: ?u32 = null,

    /// Held back before anything is allocated, to cover GUI dispatch, pipe
    /// buffering and scheduler jitter between koji deciding on a move and the
    /// clock actually stopping. Published defaults disagree by an order of
    /// magnitude (100ms, 200ms, ~500ms all appear) because the right value is a
    /// property of the deployment, not of the engine — which is why it belongs
    /// in `setoption` as `Move Overhead` rather than here. A constant until
    /// time management lands (ROADMAP Phase 3); this value is sized for local
    /// SPRT play over a pipe and is far too small for a networked bot.
    const overhead_ms = 25;

    /// Moves assumed left when the GUI names no `movestogo`. Sources put the
    /// divisor anywhere from 20 to 50 and none of them justify the number, so
    /// treat this as the SPSA knob it will become (ROADMAP Phase 5) rather than
    /// as a constant with a reason behind it.
    const assumed_moves = 40;

    /// Splits the clock into the pair above.
    ///
    /// Soft divides by the moves left, hard by their square root, so the gap
    /// between them narrows as the moves run out and closes entirely at the
    /// last one. A fixed multiple would instead keep granting a mid-flight
    /// search several times its share exactly when there is least to spare.
    ///
    /// origin: Morgan Houppin (Stash, GPL-3.0), the linear/sqrt divisor pair
    /// via https://talkchess.com/viewtopic.php?t=78330
    pub fn budget(c: Clock) Budget {
        const usable = c.remaining_ms -| overhead_ms;

        // Not from any source — the sources have a hole here. `movestogo 1`
        // drives both divisors to 1 and the formula asks for every millisecond
        // left, and UCI cannot say whether a time-control bonus follows that
        // move or whether it is sudden death, so there is no way to tell a safe
        // request from a fatal one. Keeping a quarter back is this project's
        // judgement call, not a published rule; if it is ever tuned, tune it as
        // one.
        //
        // Divided before multiplying: `usable * 3` overflows on a `wtime` near
        // `maxInt(u64)`, which is a thing a fuzzer sends and a GUI does not.
        const ceiling = usable / 4 * 3;

        const moves: u64 = @max(c.movestogo orelse assumed_moves, 1);
        // 1ms floor: below the overhead there is nothing left to divide, and a
        // budget of zero would return before even the first iteration finished,
        // leaving only the unsearched seed move to play.
        const soft = @max(1, @min(usable / moves +| c.increment_ms, ceiling));
        const hard = @max(soft, @min(usable / std.math.sqrt(moves) +| c.increment_ms, ceiling));

        return .{ .soft_ms = soft, .hard_ms = hard };
    }
};

/// What a `go` asks for. Everything is a ceiling — the search stops at whichever
/// binds first, or when `stop` arrives.
pub const Limits = struct {
    depth: u8 = max_ply,
    nodes: u64 = std.math.maxInt(u64),
    movetime_ms: ?u64 = null,
    clock: ?Clock = null,
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

    /// Two quiet moves per ply that caused a beta cutoff there, tried early at
    /// the *other* nodes of the same ply. Indexed by ply and never by remaining
    /// depth: extensions and reductions move a node's depth around, so depth
    /// aliases unrelated positions into one slot, while ply is a fixed distance
    /// from the root and so keeps a consistent side to move.
    killers: [max_ply][2]Move,

    /// The history heuristic's table. Unlike `killers` this is *not* indexed by
    /// ply: a quiet move that keeps causing cutoffs is worth trying early
    /// wherever it appears, which is precisely what killers cannot express.
    ///
    /// **Not to be confused with `history` above**, which is the Zobrist
    /// repetition history and shares nothing with this but the word.
    quiet_history: QuietHistory,

    nodes: u64,
    limits: Limits,
    start: Io.Timestamp,
    io: Io,

    /// The two deadlines of this search, nanoseconds from `start`, null when
    /// nothing time-bounded it. Derived once at `search()` entry so the poll
    /// below compares two integers rather than rebuilding a budget every
    /// `check_interval` nodes — and so that `bench`, which sets no clock, takes
    /// a path with no time in it at all.
    soft_ns: ?u64,
    hard_ns: ?u64,

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
        s.setDeadlines(s.limits);
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
        if (s.hard_ns) |ns| {
            if (s.elapsedNs() >= ns) s.stopped = true;
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

    /// Resolves `limits` into the two absolute deadlines the search actually
    /// checks. `movetime` sets only the hard one: `go movetime` is an
    /// instruction to spend that long, so declining to start an iteration would
    /// be answering a different question. A `go` naming both takes whichever is
    /// tighter, like every other limit here.
    fn setDeadlines(s: *Searcher, limits: Limits) void {
        s.soft_ns = null;
        s.hard_ns = null;

        if (limits.clock) |c| {
            const b = c.budget();
            s.soft_ns = b.soft_ms *| std.time.ns_per_ms;
            s.hard_ns = b.hard_ms *| std.time.ns_per_ms;
        }
        if (limits.movetime_ms) |ms| {
            const ns = ms *| std.time.ns_per_ms;
            s.hard_ns = @min(s.hard_ns orelse ns, ns);
        }
    }

    /// Iterative deepening. Returns the best move of the deepest iteration that
    /// *finished* — a partial iteration is discarded whole rather than mined for
    /// a better move, because its scores were produced under a window the abort
    /// invalidated.
    pub fn search(s: *Searcher, limits: Limits, reporter: ?Reporter) Result {
        s.limits = limits;
        s.setDeadlines(limits);
        s.nodes = 0;
        s.root_best = null;
        // Kept across the iterations of *this* search — a killer found at depth
        // 5 is the reason depth 6 is cheap, exactly as `root_best` is — and
        // dropped between searches, where ply N is a different position two
        // moves on. It is also what keeps `bench` a sum of independent numbers:
        // one `Searcher` runs all sixteen positions, and killers surviving into
        // the next one would make the total a fact about the file's order.
        s.killers = @splat(no_killers);
        // Cleared on the same argument, which is why the cadence here is not the
        // published one: Schaeffer halves per move played and keeps the table
        // for a whole game, which would carry state between `bench` positions.
        // Gravity is what makes clearing affordable — nothing relies on age.
        s.quiet_history = @splat(@splat(@splat(0)));
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

            // The doubling form, not `elapsed >= soft`: the next iteration is
            // assumed to cost at least as much as everything spent so far, so
            // this stops at roughly half the soft budget. Plain `>=` would
            // leave the soft limit almost inert — an iteration finishing just
            // under it starts another that this engine measures at ~5x the
            // cost (EBF 5.7 at 6->7, docs/testlog.md 2026-08-14), so every move
            // would run to the hard deadline and the pair would collapse back
            // into the single limit it exists to improve on.
            //
            // A guess about branching, not a guarantee, and unattributed in
            // every source: worth re-measuring once move ordering lands and the
            // branching factor it is guessing about changes.
            if (s.soft_ns) |ns| if (s.elapsedNs() *| 2 >= ns) break;
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

        // The ceiling answers statically — there is no room left to search in.
        // Everywhere else the horizon is handed to quiescence rather than to
        // `evaluate`, which is the whole of this branch: a leaf in the middle of
        // a capture sequence is not a position a material count can judge.
        if (ply >= max_ply) return eval.evaluate(&s.b);
        if (depth <= 0) return s.quiesce(ply, alpha_in, beta);

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

        var o: Ordered = undefined;
        movegen.generate(&s.b, &o.list);
        if (o.list.len == 0) {
            // Checkmate is scored from the mated side's view, which is the side
            // to move here; stalemate is simply a draw. Neither is stored: an
            // entry has to carry a move, and there is none.
            return if (movegen.inCheck(&s.b)) -(mate_score - @as(Score, @intCast(ply))) else 0;
        }

        // The root falls back to its own previous best only when its entry has
        // been evicted, which a small table under a long game does do.
        const first: ?Move = tt_move orelse if (ply == 0) s.root_best else null;
        o.score(&s.b, first, s.killers[ply], &s.quiet_history);

        var best = -infinity;
        // Every stored entry carries a move, including a fail-low node's: the
        // move that scored highest is still the one to try first next time.
        //
        // **Seeded after the first selection, not from `moves[0]`.** Nothing
        // reaches the store without raising `best` today, so this is currently a
        // dead store — but the moment a pruning `continue` enters the loop below,
        // an unselected seed would name whatever generation happened to emit
        // first, and the table would hand that back as the node's best move.
        var best_move = o.next(0);

        for (0..o.list.len) |i| {
            const m = if (i == 0) best_move else o.next(i);
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
                if (alpha >= beta) {
                    s.storeKiller(ply, m);
                    // `o.list.moves[0..i]` is exactly the set already searched
                    // and rejected: `next` swaps each selection into its slot as
                    // it hands it back, so the prefix is the search order and no
                    // side array has to be kept to know it.
                    s.updateQuietHistory(m, o.list.moves[0..i], depth);
                    break;
                }
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

    /// Remembers the quiet move that just caused a beta cutoff, so the other
    /// nodes at this ply try it early.
    ///
    /// **Quiets only.** A capture is already ranked by what it takes, so storing
    /// one spends a slot without adding an ordering — and spends it by evicting
    /// the quiet the slot exists to find.
    ///
    /// **The two slots must hold different moves.** Without the first test a
    /// move that cuts off twice at the same ply fills both with itself, and the
    /// second slot stops being a second guess.
    fn storeKiller(s: *Searcher, ply: u32, m: Move) void {
        if (m.kind.isCapture() or m.kind.isPromotion()) return;
        const k = &s.killers[ply];
        if (@as(u16, @bitCast(m)) == @as(u16, @bitCast(k[0]))) return;
        k[1] = k[0];
        k[0] = m;
    }

    /// Rewards the quiet move that caused this cutoff and penalises every quiet
    /// searched before it, which in that position were all wrong guesses.
    /// `tried` is that already-searched prefix, cutoff move excluded.
    ///
    /// **Quiets only, on both halves**, the rule `storeKiller` follows and for a
    /// stronger reason: captures are ranked long before this band is consulted,
    /// so an entry written for one is never read. Ranking captures by their own
    /// history needs the captured type too, and is a separate technique.
    fn updateQuietHistory(s: *Searcher, cutoff: Move, tried: []const Move, depth: i32) void {
        if (cutoff.kind.isCapture() or cutoff.kind.isPromotion()) return;

        const bonus = @min(history_slope * depth, history_bonus_max);
        s.bumpQuietHistory(cutoff, bonus);
        for (tried) |m| {
            if (m.kind.isCapture() or m.kind.isPromotion()) continue;
            s.bumpQuietHistory(m, -bonus);
        }
    }

    /// The gravity update: `h` moves toward `bonus` by less the closer it
    /// already is to the cap, which is what bounds the table without ageing it.
    ///
    /// **The bound is `|h| <= history_max`, reached and not merely approached** —
    /// growth stops at `trunc(h*B/history_max) >= B`, and `history_max` is then
    /// a fixed point. The `@intCast` relies on that being `<=`, not `<`.
    ///
    /// **The multiply is done in `Score`.** `h * |bonus|` overflows an `i16`
    /// long before the divide brings it back, and that is the reported trap.
    fn bumpQuietHistory(s: *Searcher, m: Move, bonus: Score) void {
        const e = &s.quiet_history[@intFromEnum(s.b.side)][@intFromEnum(m.from)][@intFromEnum(m.to)];
        const h: Score = e.*;
        const mag: Score = @intCast(@abs(bonus));
        e.* = @intCast(h + bonus - @divTrunc(h * mag, history_max));
    }

    /// Searches on past the horizon until nothing is hanging, so `evaluate` is
    /// only asked about positions it can judge.
    ///
    /// **Do not add a ply cap.** Captures are finite and a check can only recur
    /// here via a capture, so this terminates on its own; a cap is the classic
    /// wrong fix for a missing stand-pat or an unraised alpha. `ply >= max_ply`
    /// below is the array bound, not a search limit.
    //
    // origin: quiescence search — unclear (folklore; CPW names no originator,
    //         earliest use it records is Larry Harris, IJCAI 1975)
    // origin: stand-pat and its prohibition in check — unclear (folklore)
    //         via https://www.chessprogramming.org/Quiescence_Search
    // origin: not searching the losing captures here — unclear (folklore; CPW
    //         states it alongside delta pruning as standard practice and names
    //         no originator)
    //         via https://www.chessprogramming.org/Quiescence_Search
    fn quiesce(s: *Searcher, ply: u32, alpha_in: Score, beta: Score) Score {
        // Counted by the caller — `negamax` before delegating, the loop below
        // before descending. Incrementing here counts every horizon node twice,
        // which `bench`, `nps` and `go nodes` are all read off.
        s.pv_len[ply] = 0;

        if (s.nodes & (check_interval - 1) == 0) s.pollLimits();
        if (s.stopped) return 0;

        if (ply >= max_ply) return eval.evaluate(&s.b);

        // Not `undefined` out of habit: `= .{}` here would `memset` 2.3KB at
        // what is about to become the most-visited node type in the engine.
        var o: Ordered = undefined;
        const in_check = movegen.generateNoisy(&s.b, &o.list);

        var alpha = alpha_in;
        var best: Score = -infinity;

        if (in_check) {
            // No stand-pat: a side in check is not free to decline the reply, so
            // the static score is not a floor it can claim. An empty list is
            // therefore checkmate here and not a quiet position — the one place
            // quiescence can end a game.
            if (o.list.len == 0) return -(mate_score - @as(Score, @intCast(ply)));
        } else {
            // Stand pat. The floor under every line below: the side to move can
            // decline all of it and take the position as it stands, so no
            // capture is ever forced and a losing one is simply not played.
            best = eval.evaluate(&s.b);
            if (best >= beta) return best;
            // **Raising alpha here is not optional.** Standing pat without it
            // leaves the window as wide as the caller's and is one of the two
            // bugs that turn quiescence from a small search into an unbounded
            // one — reported as a 100:1 node ratio against a healthy 7:1.
            if (best > alpha) alpha = best;
        }

        // Scored below the stand-pat cutoff, so a node that stands pat never
        // pays for an ordering it does not use. Nothing outranks the captures
        // here: quiescence does not probe the table, so there is no first move.
        //
        // **No killers and no history either.** They are main-search devices —
        // no published description uses either here, and this list is captures
        // and promotions, which neither ever ranks. The one exception is an
        // in-check node, where `generateNoisy` hands back full evasions: those
        // quiets would be rankable, but both tables were filled by a search with
        // a depth left to spend, and nothing says they transfer to one without.
        o.score(&s.b, null, no_killers, &no_history);

        for (0..o.list.len) |i| {
            const m = o.next(i);

            // SEE pruning. A capture that loses material is not searched at all
            // here: quiescence exists to find out what is hanging, and a
            // sequence that starts by giving material away answers a question
            // nobody asked. This is where the ordering split pays — in the main
            // search a losing capture is merely late, but quiescence has no
            // depth limit to stop it and would search every one of them.
            //
            // A `break` and not a `continue`: `next` hands moves back in
            // descending order, so the first losing capture means the whole
            // remainder is losing too.
            //
            // **Only when not in check.** `generateNoisy` falls back to every
            // legal move under check, so the list is evasions rather than
            // captures — pruning there would be discarding the replies that
            // decide whether this is mate.
            if (!in_check and o.scores[i] < 0) break;

            const undo = move.makeMove(&s.b, m);
            s.nodes += 1;
            const score = -s.quiesce(ply + 1, -beta, -alpha);
            move.unmakeMove(&s.b, m, undo);

            if (s.stopped) return 0;

            if (score > best) {
                best = score;
                if (score > alpha) {
                    alpha = score;
                    if (alpha >= beta) break;
                }
            }
        }

        // Fail-soft, as `negamax` is. Nothing is stored: the table is not probed
        // or written here, so that this branch's node count and its Elo belong
        // to quiescence alone. Whether quiescence should use the table at all is
        // an open question among engine authors — reported as a clear win by
        // some and a wash by others — which makes it its own measurement rather
        // than an assumption to bundle in here.
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

// --- move ordering ------------------------------------------------------------
//
// origin: MVV-LVA — Joe Condon and Ken Thompson, "Belle Chess Hardware",
//         Advances in Computer Chess 3, 1982: the "find victim" and "find
//         aggressor" op-codes wired into Belle's move generator are the earliest
//         documented statement of the rule. The *acronym* is uncredited — CPW
//         names no one for it — so only the mechanism is attributed here.
//         via https://www.chessprogramming.org/Belle
// origin: selecting one move at a time instead of sorting the list — unclear
//         (folklore; CPW states it as what engines "usually" do and names no one)
//         via https://www.chessprogramming.org/Move_Ordering
// origin: splitting captures into winning and losing by SEE, and ranking the
//         losers below the quiets — unclear (folklore; CPW gives the band layout
//         as what engines do, credits no one, and records that many place the
//         losing captures ahead of the quiets instead)
//         via https://www.chessprogramming.org/Move_Ordering
// origin: killer moves — Barbara J. Huberman, "A Program to Play Chess End
//         Games", Stanford CS-106 / SAIL AI-65, 1968, is the earliest documented
//         description; Selim Akl and Monroe Newborn, "The Principal Continuation
//         and the Killer Heuristic", ACM 1977, named and formalised it. CPW
//         lists both alongside Gillogly 1971 and singles out no inventor.
//         via https://www.chessprogramming.org/Killer_Heuristic
// origin: the history heuristic, and its butterfly indexing — Jonathan
//         Schaeffer, "The History Heuristic", ICCA Journal 6(3):16-19, 1983.
//         The increment below is *not* his and which one was could not be
//         established; CREDITS.md carries the unresolved attribution.
//         via https://www.chessprogramming.org/History_Heuristic
// origin: the gravity update, the malus on the quiets searched before the
//         cutoff, and keeping captures out of the table — unclear (folklore;
//         CPW gives all three and names no originator for any)
//         via https://www.chessprogramming.org/History_Heuristic

/// Number of piece types, and so the spacing between victim tiers below.
const tier: Score = 6;

/// The ordering move outranks everything, a capture or promotion that does not
/// lose material outranks every quiet, the two killers sit above the quiets that
/// remain at zero, and a capture SEE says loses material sits below all of it.
/// These are ranks and not centipawns: they are only ever compared with each
/// other, never mixed with or returned as a search score.
///
/// The MVV-LVA term added to a band spans 59, so no capture can be pushed out of
/// the band it was put in. That is the only property this spacing has to have.
///
/// **A losing capture sitting last is the mainstream choice, not the only one.**
/// CPW records that many engines place them ahead of the quiets instead, on the
/// grounds that a capture is tactically loaded even when SEE calls it losing.
/// It is on the candidate list as its own test. Killers-above-losing-captures is
/// the CPW-majority layout and is just as unsettled: CPW records both that
/// placement and killers below every capture.
const first_score: Score = 1 << 20;
const noisy_score: Score = 1 << 16;
const killer_score: Score = 1 << 14;
const losing_score: Score = -(1 << 16);

/// The widest the MVV-LVA term can push a capture up inside its band — the 59
/// the spacing note above is about, derived rather than written down so the
/// history band below can assert it clears the losing band instead of eyeballing
/// it. The king term is a deliberately loose bound: a king is never a victim,
/// but an upper bound that cannot be wrong is worth more here than a tight one.
const max_ranked: Score = @intFromEnum(board.PieceType.queen) * tier +
    @intFromEnum(board.PieceType.king) * tier + (tier - 1);

/// An empty killer slot. No generated move has `from == to`, so this matches
/// nothing — the same property that lets `Ordered.score` compare against an
/// absent ordering move without branching on whether there is one.
const no_killer: Move = .init(.a1, .a1, .quiet);
const no_killers: [2]Move = @splat(no_killer);

/// How often a quiet move has caused a beta cutoff anywhere in this search,
/// indexed side-to-move x from x to — Schaeffer's butterfly board.
///
/// **Keep `scoreMove`'s quiet branch free of board reads.** That is what buys
/// this form over the denser `[piece][to]` most engines now use, which needs a
/// `pieceAt(m.from)` per quiet per node; the roadmap carries it as a candidate.
///
/// `i16` because the gravity update holds every entry within `history_max`.
const QuietHistory = [2][64][64]i16;

/// What `quiesce` passes. Its list is captures and promotions except at an
/// in-check node, and the argument at that call site for withholding killers is
/// the same argument for withholding this.
const no_history: QuietHistory = @splat(@splat(@splat(0)));

/// The gravity update's ceiling: entries settle at `history_max` rather than
/// growing, so the table needs no periodic halving.
///
/// **Do not defend these three numbers; replace them with tuned ones.** Nobody
/// in the published record can justify a particular set, and one controlled
/// experiment found the increment shape barely mattered. SPSA targets, in one
/// block so Phase 5 can wire them up without touching the algorithm.
const history_max: Score = 1 << 13;
const history_slope: Score = 128;
const history_bonus_max: Score = 1536;

comptime {
    // The bands may not overlap. A saturated history score has to stay under the
    // *second* killer and over the *best* losing capture, or a quiet starts
    // impersonating a band it was never put in — and that failure is silent,
    // because every score here is a plain integer comparison.
    std.debug.assert(history_max < killer_score - 1);
    std.debug.assert(-history_max > losing_score + max_ranked);
    // What `bumpQuietHistory` stores has to fit the entry it stores into. The
    // multiply on the way there is the separate trap, and it is handled by
    // doing it in `Score` rather than by anything assertable here.
    std.debug.assert(history_max <= std.math.maxInt(i16));
    // A single bonus may not jump the whole band in one step, or the update
    // stops being the gradual thing the ordering is supposed to learn from.
    std.debug.assert(history_bonus_max <= history_max);
}

/// What gets looked at first. Captures rank by victim, and within a victim by
/// how cheap the attacker is.
///
/// **The attacker term is a tie-break and nothing more.** Stockfish removed it
/// outright in 2015 as a simplification that passed SPRT at both time controls,
/// its author estimating the whole of LVA at half an Elo, on the reasoning that
/// most captures which cause a cutoff are captures of a hanging piece — where
/// there is only one attacker to choose between. Kept because this box is named
/// for it and it costs one mailbox read; do not defend it as load-bearing.
/// via https://github.com/official-stockfish/Stockfish/pull/340
///
/// **Killers and history are read on the quiet early-out, not beside it.** The
/// question "is this quiet" is asked once and answered for all three, so a
/// capture — every move quiescence scores — never pays for a comparison that
/// cannot match or a table read that does not apply to it.
fn scoreMove(b: *const Board, m: Move, killers: [2]Move, hist: *const QuietHistory) Score {
    const kind = m.kind;
    if (!kind.isCapture() and !kind.isPromotion()) {
        // Promotions are excluded by falling outside this branch rather than by
        // a test of their own: a queen promotion already sits with the queen
        // captures, which is above where a killer would put it.
        const bits: u16 = @bitCast(m);
        if (bits == @as(u16, @bitCast(killers[0]))) return killer_score;
        if (bits == @as(u16, @bitCast(killers[1]))) return killer_score - 1;
        // Every quiet that is not a killer ranks by history alone. The band is
        // signed: a move the search has repeatedly declined sorts *below* one it
        // has never seen, which is the whole point of the malus half.
        return hist[@intFromEnum(b.side)][@intFromEnum(m.from)][@intFromEnum(m.to)];
    }

    // A promotion ranks by what it makes on the same scale a capture ranks by
    // what it takes, so a queen promotion sits with the queen captures. A
    // capturing promotion collects both terms, which lands it *alongside* a
    // capture of what it makes rather than above it — promoting to a queen
    // while taking a pawn ties with taking a queen, and the tie stands.
    const gained: Score = if (kind.isPromotion()) @intFromEnum(kind.promoted()) * tier else 0;
    if (!kind.isCapture()) return noisy_score + gained;

    // En passant is the one capture whose victim is not standing on `m.to`, and
    // it is always a pawn taking a pawn — rank 0.
    const victim: Score = if (kind == .ep_capture) 0 else @intFromEnum(b.pieceAt(m.to).pieceType());
    const attacker: Score = @intFromEnum(b.pieceAt(m.from).pieceType());

    // Victim tiers are `tier` apart and the attacker term spans `tier - 1`, so
    // no attacker can push a capture down into a lower victim's tier.
    const ranked = gained + victim * tier + (tier - 1 - attacker);

    // MVV-LVA still ranks the captures against each other; SEE only decides
    // which band they rank in. That split is the usual one, and it is why this
    // stays a sign test rather than a re-sort by exchange value: only the top of
    // the list decides a cutoff, and an exact ordering of the losers buys
    // nothing that their being last does not already buy.
    //
    // Promotions never go to SEE — `see.winning` asserts against it. What a
    // promotion is worth turns on the piece it makes rather than on the exchange
    // on its square, and pricing that inside the swap-off is an open question
    // among engine authors rather than a settled rule. They stay in the top
    // band; the reasoning is at `see.winning`.
    if (kind.isPromotion()) return noisy_score + ranked;
    return (if (see.winning(b, m)) noisy_score else losing_score) + ranked;
}

/// A move list with its ordering scores, handed back best-first.
///
/// **Declare one `undefined`**, the rule `MoveList` already carries and for the
/// same reason: `scores` is 1.5KB that `score` fills before anything reads it.
const Ordered = struct {
    list: MoveList,
    scores: [movegen.max_moves]Score,

    /// Scores every generated move. `first` — the table's move, or the root's
    /// previous best — outranks all of them. It is scored where it lies rather
    /// than lifted out of the list, so it is still searched exactly once.
    ///
    /// One pass assigns exactly one score to each move, so the bands cannot
    /// overlap: a table move that is also this ply's killer scores `first_score`
    /// and is searched once, not once per band it belongs to. That is the
    /// failure other engines report from ordering in separate stages.
    fn score(o: *Ordered, b: *const Board, first: ?Move, killers: [2]Move, hist: *const QuietHistory) void {
        // No generated move has `from == to`, so an all-zero key matches nothing
        // and the absent case costs no branch of its own.
        const key: u16 = if (first) |m| @bitCast(m) else 0;
        for (o.list.slice(), 0..) |m, i| {
            o.scores[i] = if (@as(u16, @bitCast(m)) == key) first_score else scoreMove(b, m, killers, hist);
        }
    }

    /// Swaps the best-scored move in `[i..]` into `i` and returns it.
    ///
    /// A selection sort rather than a sort of the list, because most nodes cut
    /// off after a couple of moves: the tail is usually never fetched, and
    /// sorting it is work thrown away. **Quiescence does not finish without
    /// this at all** — removing the victim ordering it replaces cost 296x the
    /// nodes (docs/testlog.md, 2026-08-15).
    fn next(o: *Ordered, i: usize) Move {
        var best = i;
        var best_score = o.scores[i];
        for (o.scores[i + 1 .. o.list.len], i + 1..) |s, j| {
            // `>`, never `>=`, so a scan keeps the earliest of equal scores.
            // **That is not stability, and nothing may assume it is**: the swap
            // below moves the displaced move to the back of the remaining list,
            // so equal-scored moves do not come back in generation order. Ties
            // are still ordinary in the quiet band — history leaves every move
            // it has never scored at zero — so this remains exactly where the
            // assumption would be made.
            if (s > best_score) {
                best_score = s;
                best = j;
            }
        }
        std.mem.swap(Move, &o.list.moves[i], &o.list.moves[best]);
        std.mem.swap(Score, &o.scores[i], &o.scores[best]);
        return o.list.moves[i];
    }
};

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

/// The depth a fixed-depth search test runs at: `gate` on `zig build test`,
/// `deep` on `zig build test-slow`.
///
/// A ply of search test costs ~10x what it did before quiescence, so the gate
/// gave plies back and `deep` is where they went. **`deep` is the depth the test
/// ran at on `main`** — written out per site rather than as a shared offset,
/// which cannot express tests that gave up different amounts.
fn testDepth(comptime gate: u8, comptime deep: u8) u8 {
    comptime std.debug.assert(deep >= gate);
    return if (@import("build_options").slow) deep else gate;
}

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

/// Quiescence stated declaratively: the best of standing pat and every capture,
/// with no window and therefore no cutoffs. This is what `quiesce` is supposed
/// to compute, written the way the rule reads rather than the way it is
/// searched, so the two can be checked against each other.
///
/// **Only the test below may use this.** Hanging it off `referenceMinimax`'s
/// leaves multiplies two unpruned searches and the gate stops finishing.
fn referenceQuiesce(s: *Searcher, ply: u32) Score {
    if (ply >= max_ply) return eval.evaluate(&s.b);

    var list: MoveList = undefined;
    const in_check = movegen.generateNoisy(&s.b, &list);
    if (in_check and list.len == 0) return -(mate_score - @as(Score, @intCast(ply)));

    var best: Score = if (in_check) -infinity else eval.evaluate(&s.b);
    for (list.slice()) |m| {
        // The same SEE filter `quiesce` applies, stated the same way it is
        // stated there. This reference is a declaration of the rule quiescence
        // implements, and that rule now excludes losing captures — leaving it
        // out would make the test below assert the *previous* rule and fail on
        // a correct search.
        if (!in_check and m.kind.isCapture() and !m.kind.isPromotion() and
            !see.winning(&s.b, m)) continue;

        const undo = move.makeMove(&s.b, m);
        const score = -referenceQuiesce(s, ply + 1);
        move.unmakeMove(&s.b, m, undo);
        if (score > best) best = score;
    }
    return best;
}

/// Plain minimax over the same tree: no window, no cutoffs, everything else
/// identical. Alpha-beta's entire claim is that it returns this number while
/// visiting fewer nodes, so this is the reference the claim is checked against.
fn referenceMinimax(s: *Searcher, depth: i32, ply: u32) Score {
    if (ply > 0 and s.drawnByRule()) return 0;
    if (ply >= max_ply) return eval.evaluate(&s.b);
    // The real quiescence, at a full window: the leaf has to be the *same*
    // function on both sides or the comparison is not about alpha-beta any more.
    // A narrow-window bug in `quiesce` still shows up here rather than hiding,
    // because the alpha-beta side reaches this same leaf through windows the
    // reference side never opens.
    if (depth <= 0) return s.quiesce(ply, -infinity, infinity);

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
        .{ "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", testDepth(3, 4) },
        // Kiwipete: castling, pins and a dense capture set.
        .{ "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", testDepth(2, 3) },
        // Promotions and an en passant, where scores swing by a queen.
        .{ "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", testDepth(2, 4) },
        // In check at the root: six legal replies, three kinds of escape.
        .{ "4k3/8/8/8/7b/8/6P1/4K2R w K - 0 1", testDepth(2, 4) },
        // A forced mate inside the tree, which is where a ply adjustment that
        // is off by one shows up as a score and not as a crash.
        .{ "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", testDepth(3, 4) },
        // A sparse endgame: few moves, long lines, nothing to capture.
        .{ "8/8/8/3k4/8/8/3KP3/8 w - - 0 1", testDepth(4, 5) },
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

/// Positions the unpruned reference can afford, one per rule it must get right.
/// **Keep them small** — `referenceQuiesce` has no alpha-beta, so a dense
/// position is not a slow test but one that never finishes.
const quiescent_sparse = [_][]const u8{
    // A queen that can take a defended pawn: the smallest losing capture there
    // is, and the one the horizon test below is built on.
    "4k3/8/4p3/3p4/8/8/8/3QK3 w - - 0 1",
    // Promotions and an en passant, where a single ply swings by a queen.
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    // In check at the root: no stand-pat allowed, every evasion searched.
    "4k3/8/8/8/7b/8/6P1/4K2R w K - 0 1",
    // Checkmate, in check with nothing legal — quiescence has to score it.
    "R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1",
    // Quiet: nothing to capture at all, so stand-pat is the whole answer.
    "8/8/8/3k4/8/8/3KP3/8 w - - 0 1",
};

/// Where quiescence is actually hard. No reference can run against these; the
/// stand-pat floor and termination can, and those are what break here.
const quiescent_dense = [_][]const u8{
    // Kiwipete: eight captures at the root and exchanges several plies deep.
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    // Both queens loose — the shape that blows an unordered quiescence up.
    "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
};

test "quiescence returns exactly what the rule it implements returns" {
    // The minimax test above, for the other half of the search. Catches a
    // stand-pat cutting on the wrong side of beta, an alpha never raised after
    // it, and a mate score that forgot its ply.
    for (quiescent_sparse) |fen| {
        const s = try searcher(fen);
        defer testing.allocator.destroy(s);

        const expected = referenceQuiesce(s, 0);
        const actual = s.quiesce(0, -infinity, infinity);
        testing.expectEqual(expected, actual) catch |err| {
            std.debug.print("quiescence mismatch in {s}\n", .{fen});
            return err;
        };
    }
}

test "quiescence never scores below standing pat" {
    // Returning the best *capture* instead of the best of {stand pat, captures}
    // fails here wherever every capture loses material. Includes the dense
    // positions: needs no reference, and doubles as a termination check.
    for (quiescent_sparse ++ quiescent_dense) |fen| {
        const s = try searcher(fen);
        defer testing.allocator.destroy(s);
        if (movegen.inCheck(&s.b)) continue; // no stand-pat when in check

        try testing.expect(s.quiesce(0, -infinity, infinity) >= eval.evaluate(&s.b));
    }
}

test "quiescence scores a mate rather than standing pat in check" {
    // The one place quiescence ends a game. Getting this wrong reads from
    // outside exactly like a TT collision, hence its own test.
    const s = try searcher("R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1");
    defer testing.allocator.destroy(s);

    try testing.expectEqual(-mate_score, s.quiesce(0, -infinity, infinity));
    // ...and one ply further down it is one point less bad, so the search still
    // prefers the mate that takes longer to arrive.
    try testing.expectEqual(-(mate_score - 3), s.quiesce(3, -infinity, infinity));
}

test "a queen taken at the horizon is no longer counted as won material" {
    // d5 is defended by e6, so Qxd5 wins a pawn and loses a queen one ply later.
    // Scoring leaves statically, depth 1 sees only the pawn: +800, best move.
    const s = try searcher("4k3/8/4p3/3p4/8/8/8/3QK3 w - - 0 1");
    defer testing.allocator.destroy(s);

    const result = s.search(.{ .depth = 1 }, null);

    // Two pawns down for Black and nothing given away: the queen keeps its
    // distance, so the score is what the position is already worth plus at most
    // the square the queen improves onto — and nowhere near the extra pawn that
    // a horizon-blind depth-1 search would claim for Qxd5.
    //
    // Stated as a bound off the static score rather than the literal it used to
    // be: the literal was `queen - two pawns` under a material-only eval, and
    // pinning a number that PSQT is expected to move would make this a test of
    // the tuning instead of a test of quiescence.
    const static = eval.evaluate(&s.b);
    try testing.expect(result.score >= static);
    try testing.expect(result.score < static + eval.piece_value_mg[@intFromEnum(board.PieceType.pawn)]);

    var buf: [8]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try result.move.?.format(&w);
    try testing.expect(!std.mem.eql(u8, "d1d5", w.buffered()));
}

test "a narrow window never changes which side of it the true score falls on" {
    // Alpha-beta is only score-exact inside its window; outside it, fail-soft
    // promises a *bound*. That bound is what a transposition table will store,
    // so it is worth pinning now: a search returning <= alpha must not be hiding
    // a score above it, and one returning >= beta must not be hiding one below.
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);

    const depth = testDepth(2, 3);
    const truth = s.negamax(depth, 0, -infinity, infinity);

    var offset: Score = -300;
    while (offset <= 300) : (offset += 100) {
        const alpha = truth + offset;
        const beta = alpha + 1;
        s.root_best = null;
        const bound = s.negamax(depth, 0, alpha, beta);
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

        const result = s.search(.{ .depth = testDepth(3, 4) }, null);
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
    _ = s.search(.{ .depth = testDepth(3, 4) }, null);

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

    const first = s.search(.{ .depth = testDepth(3, 4) }, null);
    const second = s.search(.{ .depth = testDepth(3, 4) }, null);

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

/// Every clock the budget tests below run over. Spread deliberately across the
/// regimes that behave differently: sudden death with and without increment,
/// a GUI-supplied `movestogo` at both ends of its range, an increment larger
/// than the clock it is added to, and the low-time cases where the arithmetic
/// is at risk of underflowing.
const clocks = [_]Clock{
    .{ .remaining_ms = 8000, .increment_ms = 80 }, // 8+0.08, the SPRT control
    .{ .remaining_ms = 300_000, .increment_ms = 0 },
    .{ .remaining_ms = 300_000, .increment_ms = 3000 },
    .{ .remaining_ms = 60_000, .increment_ms = 0, .movestogo = 40 },
    .{ .remaining_ms = 60_000, .increment_ms = 0, .movestogo = 1 },
    .{ .remaining_ms = 1000, .increment_ms = 10_000 }, // increment dwarfs the clock
    .{ .remaining_ms = 100, .increment_ms = 0 },
    .{ .remaining_ms = 26, .increment_ms = 0 }, // one millisecond of usable time
    .{ .remaining_ms = 25, .increment_ms = 0 }, // exactly the overhead
    .{ .remaining_ms = 1, .increment_ms = 0 },
    .{ .remaining_ms = 0, .increment_ms = 0 }, // already flagging
};

test "a budget is ordered, positive, and never spends a clock it does not have" {
    for (clocks) |c| {
        const b = c.budget();

        // Starting an iteration you cannot finish is the thing the soft limit
        // exists to prevent, so it can never be the later of the two.
        try testing.expect(b.soft_ms <= b.hard_ms);

        // Zero would mean returning before the first iteration completes, and
        // the seeded root move is a legal move but not a searched one.
        try testing.expect(b.soft_ms >= 1);

        // Below the overhead there is nothing left to allocate and the engine
        // answers with the 1ms floor above, which is legitimately more than the
        // clock holds. Everywhere else, spending more than the clock is a flag.
        if (c.remaining_ms > Clock.overhead_ms) {
            try testing.expect(b.hard_ms <= c.remaining_ms);
        }
    }
}

test "the last move before a time control keeps a reserve" {
    // `movestogo 1` drives both divisors to 1, so the formula on its own asks
    // for the entire remaining clock. UCI cannot say whether a bonus follows
    // that move, so the reserve is the only thing standing between the engine
    // and a flag. See the `ceiling` comment on `Clock.budget`.
    const c: Clock = .{ .remaining_ms = 60_000, .movestogo = 1 };
    const b = c.budget();
    const usable = c.remaining_ms - Clock.overhead_ms;

    try testing.expect(b.hard_ms < usable);
    // Not merely "less than": a reserve that rounds to nothing is not a reserve.
    try testing.expect(usable - b.hard_ms > usable / 5);
}

test "a budget grows with the clock and never shrinks" {
    // The property that makes the budget safe under repeated application: as a
    // game burns down the clock the allocation follows it down, and no step of
    // that descent may hand back *more* time than the step before.
    var previous: u64 = 0;
    var remaining: u64 = 0;
    while (remaining <= 300_000) : (remaining += 137) {
        const b = (Clock{ .remaining_ms = remaining, .increment_ms = 50 }).budget();
        try testing.expect(b.hard_ms >= previous);
        previous = b.hard_ms;
    }
}

test "a clock alone stops an otherwise unbounded search" {
    const s = try searcher(null);
    defer testing.allocator.destroy(s);

    // No depth ceiling at all — the clock is the only thing that can end this,
    // which is the whole point. The node limit is a backstop so that a budget
    // that never binds fails the assertion below instead of hanging the suite.
    const backstop = 20_000_000;
    const result = s.search(.{
        .nodes = backstop,
        .clock = .{ .remaining_ms = 200, .increment_ms = 0 },
    }, null);

    try testing.expect(result.nodes < backstop);
    try testing.expect(result.move != null);

    // A search cut short still owes the caller a move it is legal to play.
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
    const with_ordering = deepened.search(.{ .depth = testDepth(2, 4) }, null).score;

    const cold = try searcher(fen);
    defer testing.allocator.destroy(cold);
    cold.root_best = null;
    const without_ordering = cold.negamax(testDepth(2, 4), 0, -infinity, infinity);

    try testing.expectEqual(without_ordering, with_ordering);
}

test "ordering hands every move back exactly once, best first" {
    // The selection-sort bug perft cannot see: perft never orders, so a swap
    // that drops or duplicates a move surfaces only as a wrong search.
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    };

    for (fens) |fen| {
        const s = try searcher(fen);
        defer testing.allocator.destroy(s);

        var o: Ordered = undefined;
        movegen.generate(&s.b, &o.list);
        const len = o.list.len;

        var original: [movegen.max_moves]u16 = undefined;
        for (o.list.slice(), 0..) |m, i| original[i] = @bitCast(m);

        // The *last* generated move as the ordering move, so the path that
        // lifts one out of the far end of the list runs rather than a no-op.
        o.score(&s.b, o.list.moves[len - 1], no_killers, &no_history);

        var previous: Score = first_score;
        for (0..len) |i| {
            const m = o.next(i);
            if (i == 0) try testing.expectEqual(original[len - 1], @as(u16, @bitCast(m)));
            try testing.expect(o.scores[i] <= previous);
            previous = o.scores[i];

            // Strike it off. No move bitcasts to zero — a generated move never
            // has `from == to` — so zero is a safe "already seen" marker.
            var found = false;
            for (original[0..len]) |*seen| {
                if (seen.* == @as(u16, @bitCast(m))) {
                    seen.* = 0;
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }
}

test "MVV-LVA takes the biggest victim, and then the cheapest attacker" {
    const cases = [_]struct { fen: []const u8, want: []const u8 }{
        // Pawn takes queen against queen takes pawn: the victim decides.
        .{ .fen = "4k3/8/1p2q3/QP1P4/8/8/8/6K1 w - - 0 1", .want = "d5e6" },
        // One victim, two attackers, so only the attacker term can choose —
        // and it has to send the knight in ahead of the queen.
        .{ .fen = "4k3/8/8/3r4/5N2/8/8/3QK3 w - - 0 1", .want = "f4d5" },
        // A queen promotion ranks with the queen captures, so it goes before a
        // rook taking a knight.
        .{ .fen = "k7/3P4/8/8/8/8/8/4K1nR w - - 0 1", .want = "d7d8q" },
    };

    for (cases) |case| {
        const s = try searcher(case.fen);
        defer testing.allocator.destroy(s);

        var o: Ordered = undefined;
        movegen.generate(&s.b, &o.list);
        o.score(&s.b, null, no_killers, &no_history);

        const want = move.Move.fromUci(&s.b, case.want).?;
        try testing.expectEqual(@as(u16, @bitCast(want)), @as(u16, @bitCast(o.next(0))));
    }
}

/// The score `o` gave the move `uci` names, or null if it was never generated.
fn scoreOfUci(o: *const Ordered, b: *const Board, uci: []const u8) ?Score {
    const want: u16 = @bitCast(move.Move.fromUci(b, uci).?);
    for (o.list.slice(), 0..) |m, i| {
        if (@as(u16, @bitCast(m)) == want) return o.scores[i];
    }
    return null;
}

test "en passant is scored as the pawn it takes, not as the empty square it lands on" {
    // The one capture whose victim is not standing on `m.to`. Reading the victim
    // off the destination would score this against an empty square instead —
    // and `pieceType()` on `.none` is an assert that is compiled out of the
    // build every measurement is taken on.
    const ep = try searcher("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    defer testing.allocator.destroy(ep);
    var eo: Ordered = undefined;
    movegen.generate(&ep.b, &eo.list);
    eo.score(&ep.b, null, no_killers, &no_history);

    // The same pawn taking the same pawn on the same square, arrived at
    // normally: en passant has to score identically to it.
    const plain = try searcher("4k3/8/3p4/4P3/8/8/8/4K3 w - - 0 1");
    defer testing.allocator.destroy(plain);
    var po: Ordered = undefined;
    movegen.generate(&plain.b, &po.list);
    po.score(&plain.b, null, no_killers, &no_history);

    const by_rule = scoreOfUci(&eo, &ep.b, "e5d6").?;
    try testing.expectEqual(scoreOfUci(&po, &plain.b, "e5d6").?, by_rule);
    // ...and it is still a capture, not a quiet.
    try testing.expect(by_rule >= noisy_score);
}

test "a capturing promotion collects both terms" {
    // The only move that adds `gained` to a victim, and the only place the two
    // could be transposed or one of them dropped without another test firing.
    const s = try searcher("3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1");
    defer testing.allocator.destroy(s);

    var o: Ordered = undefined;
    movegen.generate(&s.b, &o.list);
    o.score(&s.b, null, no_killers, &no_history);

    const taking = scoreOfUci(&o, &s.b, "e7d8q").?;
    const quiet_promo = scoreOfUci(&o, &s.b, "e7e8q").?;
    const under = scoreOfUci(&o, &s.b, "e7d8n").?;

    // Taking the rook on the way in beats promoting to the same piece quietly,
    // and promoting to a queen beats promoting to a knight on the same square.
    try testing.expect(taking > quiet_promo);
    try testing.expect(taking > under);
    try testing.expectEqual(@as(u16, @bitCast(move.Move.fromUci(&s.b, "e7d8q").?)), @as(u16, @bitCast(o.next(0))));
}

test "the ordering move goes first, and one that is not in the list changes nothing" {
    const fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    const s = try searcher(fen);
    defer testing.allocator.destroy(s);

    // A quiet rook shuffle: it scores zero on its own and would otherwise sort
    // behind every capture on the board.
    var o: Ordered = undefined;
    movegen.generate(&s.b, &o.list);
    const quiet = move.Move.fromUci(&s.b, "a1b1").?;
    o.score(&s.b, quiet, no_killers, &no_history);
    try testing.expectEqual(@as(u16, @bitCast(quiet)), @as(u16, @bitCast(o.next(0))));

    // A move from an unrelated position, which is what a table collision hands
    // back: it must simply not be found, leaving the order it would have had.
    var collided: Ordered = undefined;
    movegen.generate(&s.b, &collided.list);
    collided.score(&s.b, move.Move.init(.a4, .a5, .quiet), no_killers, &no_history);

    var plain: Ordered = undefined;
    movegen.generate(&s.b, &plain.list);
    plain.score(&s.b, null, no_killers, &no_history);

    for (0..plain.list.len) |i| {
        try testing.expectEqual(
            @as(u16, @bitCast(plain.next(i))),
            @as(u16, @bitCast(collided.next(i))),
        );
    }
}

const kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";

test "a killer outranks every other quiet, and still ranks behind the captures" {
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);

    // Castling, so this covers the one quiet move whose `kind` is neither
    // `.quiet` nor a capture — nothing excludes it, and nothing should.
    const killer = move.Move.fromUci(&s.b, "e1g1").?;

    var o: Ordered = undefined;
    movegen.generate(&s.b, &o.list);
    o.score(&s.b, null, .{ killer, no_killer }, &no_history);

    try testing.expectEqual(killer_score, scoreOfUci(&o, &s.b, "e1g1").?);
    // Bishop takes bishop: an equal trade, so SEE leaves it in the top band and
    // the killer has to stay under it.
    try testing.expect(scoreOfUci(&o, &s.b, "e2a6").? > killer_score);

    // ...and every quiet that is not the killer is still an unranked zero.
    for (o.list.slice(), 0..) |m, i| {
        if (@as(u16, @bitCast(m)) == @as(u16, @bitCast(killer))) continue;
        if (m.kind.isCapture() or m.kind.isPromotion()) continue;
        try testing.expectEqual(@as(Score, 0), o.scores[i]);
    }
}

test "the second killer ranks behind the first, and both ahead of the quiets" {
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);

    const primary = move.Move.fromUci(&s.b, "a1b1").?;
    const secondary = move.Move.fromUci(&s.b, "h1g1").?;

    var o: Ordered = undefined;
    movegen.generate(&s.b, &o.list);
    o.score(&s.b, null, .{ primary, secondary }, &no_history);

    const first = scoreOfUci(&o, &s.b, "a1b1").?;
    const second = scoreOfUci(&o, &s.b, "h1g1").?;
    try testing.expectEqual(killer_score, first);
    try testing.expect(second < first);
    // The gap is one rank, so no quiet can ever be spelled between them.
    try testing.expectEqual(@as(Score, 1), first - second);
    try testing.expect(second > 0);
}

test "storing shifts the slots down and never fills both with one move" {
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    s.killers = @splat(no_killers);

    const a = move.Move.fromUci(&s.b, "a1b1").?;
    const b = move.Move.fromUci(&s.b, "h1g1").?;

    s.storeKiller(3, a);
    try testing.expectEqual(@as(u16, @bitCast(a)), @as(u16, @bitCast(s.killers[3][0])));

    s.storeKiller(3, b);
    try testing.expectEqual(@as(u16, @bitCast(b)), @as(u16, @bitCast(s.killers[3][0])));
    try testing.expectEqual(@as(u16, @bitCast(a)), @as(u16, @bitCast(s.killers[3][1])));

    // The same move cutting off twice must not evict the second guess with a
    // copy of the first — that is what makes the second slot dead.
    s.storeKiller(3, b);
    try testing.expectEqual(@as(u16, @bitCast(b)), @as(u16, @bitCast(s.killers[3][0])));
    try testing.expectEqual(@as(u16, @bitCast(a)), @as(u16, @bitCast(s.killers[3][1])));

    // One ply's slots are its own.
    try testing.expectEqual(@as(u16, @bitCast(no_killer)), @as(u16, @bitCast(s.killers[4][0])));
}

test "a capture or a promotion never becomes a killer" {
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    s.killers = @splat(no_killers);

    s.storeKiller(0, move.Move.fromUci(&s.b, "e2a6").?);
    try testing.expectEqual(@as(u16, @bitCast(no_killer)), @as(u16, @bitCast(s.killers[0][0])));

    const p = try searcher("3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1");
    defer testing.allocator.destroy(p);
    p.killers = @splat(no_killers);

    // Both halves: the quiet promotion and the capturing one. Neither is a
    // capture-flagged quiet, and neither may take a slot.
    p.storeKiller(0, move.Move.fromUci(&p.b, "e7e8q").?);
    p.storeKiller(0, move.Move.fromUci(&p.b, "e7d8q").?);
    try testing.expectEqual(@as(u16, @bitCast(no_killer)), @as(u16, @bitCast(p.killers[0][0])));
}

test "a killer that is not legal here changes the order not at all" {
    // A killer is learned at a sibling node, so most of them do not exist in
    // this position. Nothing verifies one before it is used: it is a `u16`
    // compared against moves `generate` has already emitted, so an absent
    // killer simply matches nothing — the same guarantee the ordering move has.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);

    var stale: Ordered = undefined;
    movegen.generate(&s.b, &stale.list);
    stale.score(&s.b, null, .{ move.Move.init(.a4, .a5, .quiet), move.Move.init(.b7, .b6, .quiet) }, &no_history);

    var plain: Ordered = undefined;
    movegen.generate(&s.b, &plain.list);
    plain.score(&s.b, null, no_killers, &no_history);

    for (0..plain.list.len) |i| {
        try testing.expectEqual(
            @as(u16, @bitCast(plain.next(i))),
            @as(u16, @bitCast(stale.next(i))),
        );
    }
}

test "killers are reached by a real search, and it costs fewer nodes for them" {
    // The bound is what this position cost at this depth with the killer band
    // ablated out of the scorer and nothing else changed, so it is one-sided in
    // the same way as the test above: only a search that got worse can breach
    // it.
    //
    // **Recalibrated when PSQT landed, because the old bound measured a
    // different engine.** A node count is only comparable against the eval that
    // produced the tree, so 3,438,106 — the material-only ablation — became
    // meaningless the moment the leaves started returning different numbers.
    // Re-measured here: 3,849,447 ablated against 3,799,071 live, a margin of
    // 1.31% where the material-only eval managed 0.25%. That five-fold jump is
    // the answer to the question docs/testlog.md, 2026-08-16 parked — killers
    // were never the problem, the eval they ordered against was.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    try testing.expect(s.search(.{ .depth = 7 }, null).nodes < 3_849_447);
}

// --- history heuristic --------------------------------------------------------

/// Drives one entry with `n` bonuses of `bonus` and hands back what it holds.
/// The move is a quiet `a2a3` so nothing else in the update can reject it.
fn drive(s: *Searcher, n: usize, bonus: Score) Score {
    const m = move.Move.init(.a2, .a3, .quiet);
    for (0..n) |_| s.bumpQuietHistory(m, bonus);
    return s.quiet_history[@intFromEnum(s.b.side)][@intFromEnum(m.from)][@intFromEnum(m.to)];
}

test "a saturated history score stays inside its band" {
    // The property the comptime asserts at `history_max` state, checked against
    // the update that is supposed to maintain it rather than against arithmetic
    // repeated here. Both signs, because the malus half is what put a negative
    // number in the quiet band in the first place.
    const s = try searcher(null);
    defer testing.allocator.destroy(s);
    s.quiet_history = @splat(@splat(@splat(0)));

    // Far more bonuses than any real node applies, at the largest one the bonus
    // formula can produce: if the bound can be breached at all, it is here.
    const high = drive(s, 10_000, history_bonus_max);
    try testing.expectEqual(history_max, high);
    try testing.expect(high < killer_score - 1);

    s.quiet_history = @splat(@splat(@splat(0)));
    const low = drive(s, 10_000, -history_bonus_max);
    try testing.expectEqual(-history_max, low);
    try testing.expect(low > losing_score + max_ranked);
}

test "the gravity update settles rather than overflowing i16" {
    // The reported trap for 16-bit entries: `h * |bonus|` overflows long before
    // the divide brings it back, so the multiply has to happen in `Score`. An
    // overflow here is a panic in a Debug or ReleaseSafe test build, so this
    // test fires as a crash and not as a wrong number — which is what makes it
    // worth writing separately from the band test above.
    const s = try searcher(null);
    defer testing.allocator.destroy(s);
    s.quiet_history = @splat(@splat(@splat(0)));

    // Once at the ceiling it is a fixed point: further bonuses may not move it.
    const settled = drive(s, 500, history_bonus_max);
    try testing.expectEqual(history_max, settled);
    try testing.expectEqual(history_max, drive(s, 500, history_bonus_max));

    // And it is reversible — a saturated entry comes back down under malus,
    // which is what stops a move being permanently ranked on stale evidence.
    try testing.expect(drive(s, 1, -history_bonus_max) < history_max);
}

test "a cutoff rewards the move and penalises the quiets tried before it" {
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    s.quiet_history = @splat(@splat(@splat(0)));

    const cutoff = move.Move.fromUci(&s.b, "a1b1").?;
    const early = move.Move.fromUci(&s.b, "h1g1").?;
    const capture = move.Move.fromUci(&s.b, "e2a6").?;

    s.updateQuietHistory(cutoff, &.{ early, capture }, 4);

    const h = &s.quiet_history[@intFromEnum(s.b.side)];
    try testing.expect(h[@intFromEnum(cutoff.from)][@intFromEnum(cutoff.to)] > 0);
    try testing.expect(h[@intFromEnum(early.from)][@intFromEnum(early.to)] < 0);
    // The capture in the prefix is skipped on the malus half for the same reason
    // it could never take the bonus: captures are ranked before this band is
    // ever consulted, so an entry written for one is written and never read.
    try testing.expectEqual(
        @as(i16, 0),
        h[@intFromEnum(capture.from)][@intFromEnum(capture.to)],
    );
}

test "a capture or a promotion cutoff writes nothing at all" {
    // The same guard `storeKiller` carries, checked the same way — and it has to
    // cover the whole call, not just the bonus: a capture cutoff must not hand
    // out a malus to the quiets before it either, because the quiets were not
    // refuted by anything a capture proved.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    s.quiet_history = @splat(@splat(@splat(0)));

    const quiet = move.Move.fromUci(&s.b, "h1g1").?;
    s.updateQuietHistory(move.Move.fromUci(&s.b, "e2a6").?, &.{quiet}, 4);

    const p = try searcher("3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1");
    defer testing.allocator.destroy(p);
    p.quiet_history = @splat(@splat(@splat(0)));
    p.updateQuietHistory(move.Move.fromUci(&p.b, "e7e8q").?, &.{}, 4);

    try testing.expectEqual(no_history, s.quiet_history);
    try testing.expectEqual(no_history, p.quiet_history);
}

test "a history score never reaches the killers or the losing captures" {
    // The band test with a real move list under it: saturating a quiet's entry
    // must not let it impersonate a killer, and must still leave it above every
    // losing capture. This is the failure that is silent — every score here is a
    // plain integer comparison, so an overlap reorders the list and nothing
    // else happens.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    s.quiet_history = @splat(@splat(@splat(0)));

    const quiet = move.Move.fromUci(&s.b, "a1b1").?;
    for (0..10_000) |_| s.bumpQuietHistory(quiet, history_bonus_max);

    var o: Ordered = undefined;
    movegen.generate(&s.b, &o.list);
    o.score(&s.b, null, .{ move.Move.fromUci(&s.b, "h1g1").?, no_killer }, &s.quiet_history);

    const saturated = scoreOfUci(&o, &s.b, "a1b1").?;
    try testing.expectEqual(history_max, saturated);
    // Under the *second* killer, which is the tighter of the two bounds.
    try testing.expect(saturated < killer_score - 1);
    try testing.expect(scoreOfUci(&o, &s.b, "h1g1").? > saturated);

    // ...and stated over the whole list rather than against a hand-picked move,
    // which is what makes it a band test: no capture or promotion, in either
    // band, may land anywhere history can reach. Naming one move instead would
    // assert this position's SEE verdict as much as the spacing.
    var noisy: usize = 0;
    var losing: usize = 0;
    for (o.list.slice(), 0..) |m, i| {
        if (!m.kind.isCapture() and !m.kind.isPromotion()) continue;
        const sc = o.scores[i];
        try testing.expect(sc > history_max or sc < -history_max);
        if (sc > history_max) noisy += 1 else losing += 1;
    }
    // Both bands have to be populated or the loop above proved half a property.
    try testing.expect(noisy > 0);
    try testing.expect(losing > 0);
}

test "the table does not survive into the next search" {
    // The bench invariant as a unit test. One `Searcher` runs all sixteen bench
    // positions, so a table carried across `search()` calls would make the total
    // a fact about the order of `testdata/bench.epd` rather than a sum of
    // sixteen independent numbers — and it would do it silently, because the
    // total stays perfectly deterministic either way.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);

    const first = s.search(.{ .depth = testDepth(5, 6) }, null).nodes;
    const second = s.search(.{ .depth = testDepth(5, 6) }, null).nodes;
    try testing.expectEqual(first, second);
}

test "history is reached by a real search, and it costs fewer nodes for it" {
    // 3,799,071 is what this position cost at this depth with the history band
    // ablated out of the scorer and nothing else changed — and it is the same
    // number the killers test above quotes as its live figure, which is the
    // check that the ablation is clean: with history switched off the engine is
    // exactly the one that merged as #25. Live it costs 3,789,513.
    //
    // **A 0.25% margin, where `bench` sees 10.89%.** The two are not in tension
    // — this is one position at one depth and `bench` is sixteen — but the
    // bound is deliberately the honest small number rather than the flattering
    // one, and it is one-sided in the usual way: only a search that got worse
    // can breach it.
    const s = try searcher(kiwipete);
    defer testing.allocator.destroy(s);
    try testing.expect(s.search(.{ .depth = 7 }, null).nodes < 3_799_071);
}

test "ordering is applied, and the search costs fewer nodes for it" {
    // The test that fires if the scorer is wired up but never actually reached.
    // The bound is what this position cost at this depth on `main` at the commit
    // before ordering existed, which makes it one-sided: a search that gets
    // better only ever moves further under it, so it never needs raising.
    const s = try searcher("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    defer testing.allocator.destroy(s);
    try testing.expect(s.search(.{ .depth = 3 }, null).nodes < 1_300_546);
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

        // The same ladder the table-off version of this test climbs: what makes
        // this one sharp is the two slots, not the depth, and every extra ply
        // here is paid by `zig build test` on every turn.
        var depth: u8 = 1;
        while (depth <= testDepth(3, 4)) : (depth += 1) {
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
    //
    // A pawn endgame rather than Kiwipete, and that is the *sharper* choice as
    // well as the cheaper one. Transpositions are what this test is about, and a
    // position with four pieces and no capture available at all is where move
    // orders converge hardest — while costing quiescence nothing, since it has
    // nothing to search. Kiwipete measured the same claim through several
    // seconds of capture tree that had no bearing on it.
    const fen = "8/8/8/3k4/8/8/3KP3/8 w - - 0 1";

    const without = try searcher(fen);
    defer testing.allocator.destroy(without);
    const cold = without.search(.{ .depth = 6 }, null);

    var table = try realTable();
    defer table.deinit(testing.allocator);
    const with = try searcherWith(fen, &table);
    defer testing.allocator.destroy(with);
    const warm = with.search(.{ .depth = 6 }, null);

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
    const first = s.search(.{ .depth = testDepth(3, 5) }, null);
    table.clear();
    const second = s.search(.{ .depth = testDepth(3, 5) }, null);

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
