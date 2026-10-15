const std = @import("std");

const reference_sources = [_][]const u8{
    "optimal.cpp",
    "src/board.cpp",
    "src/eight_way.cpp",
    "src/zini.cpp",
    "src/exact/schedule.cpp",
    "src/exact/solver.cpp",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const root_module = solverModule(b, target, optimize);
    const exe = b.addExecutable(.{ .name = "optimal", .root_module = root_module });
    b.installArtifact(exe);
    b.installArtifact(referenceExecutable(b, target, optimize));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the solver").dependOn(&run_cmd.step);

    const compare_module = b.createModule(.{
        .root_source_file = b.path("compare/compare.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });

    const compare = b.addExecutable(.{ .name = "compare", .root_module = compare_module });
    const run_compare = b.addRunArtifact(compare);
    run_compare.addArtifactArg(b.addExecutable(.{ .name = "optimal-fast", .root_module = solverModule(b, target, .ReleaseFast) }));
    run_compare.addArtifactArg(referenceExecutable(b, target, .ReleaseFast));
    run_compare.addPassthruArgs();
    b.step("compare", "Check the solver against the C++ reference and time both").dependOn(&run_compare.step);
}

fn solverModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn referenceExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    module.addCSourceFiles(.{
        .root = b.path("reference"),
        .files = &reference_sources,
        .flags = &.{ "-std=c++20", "-DNDEBUG", "-O3" },
    });
    return b.addExecutable(.{ .name = "optimal-reference", .root_module = module });
}
