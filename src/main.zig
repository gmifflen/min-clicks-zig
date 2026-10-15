const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const solve_command = @import("solve_command.zig");
const report = @import("report.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    var diag: cli.Diagnostic = .{};
    const command = cli.parse(arena, args[1..], &diag) catch |err| return fail(switch (err) {
        error.InvalidArguments => diag.message,
        error.OutOfMemory => "Out of memory",
    });
    const config = switch (command) {
        .help => {
            try out.writeAll(cli.usage);
            try out.flush();
            return 0;
        },
        .solve => |config| config,
    };
    var progress_buffer: [256]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &progress_buffer);
    const progress: ?*Io.Writer = if (config.log_progress) &stderr.interface else null;
    const solved = solve_command.solve(init.gpa, arena, init.io, config, progress) catch |err| return fail(solve_command.describeError(err));
    if (config.json) {
        try report.writeJson(out, &solved.board, solved.results, config.witness);
    } else {
        try report.writeText(out, &solved.board, solved.results, config.witness);
    }
    try out.flush();
    return solved.exitCode();
}

fn fail(message: []const u8) u8 {
    std.debug.print("Error: {s}\n", .{message});
    return 1;
}
