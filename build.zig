const std = @import("std");
const builtin = @import("builtin");

// The toolchain is pinned exactly. Zig's std and build API are still moving fast
// enough that "0.16 or newer" is not a meaningful constraint: 0.17 already renames
// things this file uses. A hard failure here is much cheaper than a confusing one
// several hundred lines into a build.
comptime {
    const required: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };
    if (builtin.zig_version.order(required) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "koji requires Zig {f} exactly, found {f}",
            .{ required, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Deliberately *not* `standardOptimizeOption`. Passing it a
    // `preferred_optimize_mode` does not make that mode the default for a bare
    // `zig build` — it replaces -Doptimize with a -Drelease bool and still hands
    // back Debug unless -Drelease is passed (std.Build.zig:1378). That silently
    // benchmarks a Debug binary, which for an engine is 3x off and pure noise.
    // An engine built in Debug by accident is not slightly slow, it is useless.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // SPSA tuning parameters become UCI options only when this is set, and it stays
    // off by default: a build advertising dozens of internal tuning knobs breaks GUIs
    // that enumerate options. Tuning runs pass -Dtunables explicitly.
    const tunables = b.option(
        bool,
        "tunables",
        "Expose SPSA tuning parameters as UCI options (development only, never in a release)",
    ) orelse false;

    // --- the shipped binary -------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "koji",
        .root_module = engineModule(b, .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .tunables = tunables,
            .slow = false,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the engine (pass args after --)");
    run_step.dependOn(&run_cmd.step);

    // --- tests --------------------------------------------------------------

    // Tests are built ReleaseSafe rather than at `optimize`. Safety checks are the
    // point of a test run, but perft at Debug speed would blow the <5s budget that
    // makes `zig build test` cheap enough to gate every turn on.
    const test_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const test_step = b.step("test", "Unit tests + shallow perft (fast; gates every turn)");
    const fast_tests = b.addTest(.{
        .root_module = engineModule(b, .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .tunables = tunables,
            .slow = false,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fast_tests).step);

    const test_slow_step = b.step("test-slow", "Deep perft (minutes; run before merging movegen work)");
    const slow_tests = b.addTest(.{
        .root_module = engineModule(b, .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
            .tunables = tunables,
            .slow = true,
        }),
    });
    test_slow_step.dependOn(&b.addRunArtifact(slow_tests).step);

    // --- bench --------------------------------------------------------------

    // OpenBench reads `<nodes> nodes <nps> nps` off this. It is also the number that
    // goes in every commit message touching search or eval.
    const bench_cmd = b.addRunArtifact(exe);
    bench_cmd.addArg("bench");
    bench_cmd.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run the fixed benchmark position set");
    bench_step.dependOn(&bench_cmd.step);
}

const ModuleOptions = struct {
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tunables: bool,
    slow: bool,
};

/// Every module is given an explicit `optimize`. A module that leaves it null emits
/// no -O flag at all and silently picks up whatever the compilation defaults to,
/// which is exactly the kind of thing that produces an unexplained 3x in a bench.
fn engineModule(b: *std.Build, opts: ModuleOptions) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "tunables", opts.tunables);
    options.addOption(bool, "slow", opts.slow);

    const mod = b.createModule(.{
        .root_source_file = opts.root_source_file,
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addOptions("build_options", options);

    // The perft oracle, reachable from `@embedFile("perft_epd")`. It lives outside
    // src/, and @embedFile resolves relative to the module root, so a bare
    // "../testdata/perft.epd" is rejected as an embed outside the package path.
    // Naming it as an import is the way across that boundary. Only tests read it;
    // an unreferenced import costs the shipped binary nothing.
    mod.addAnonymousImport("perft_epd", .{ .root_source_file = b.path("testdata/perft.epd") });

    return mod;
}
