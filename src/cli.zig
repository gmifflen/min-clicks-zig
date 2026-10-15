const std = @import("std");
const Allocator = std.mem.Allocator;
const exact = @import("exact/exact.zig");
const Limits = exact.Limits;

pub const usage =
    \\Usage: optimal URL [options]
    \\       optimal --random WIDTH HEIGHT MINES SEED [--64b] [options]
    \\  --64b       Use mt19937_64 and a uint64 seed for random boards
    \\  --algorithm optimal|8way|lzini|hzini (default optimal)
    \\  --all       All four algorithms, one JSON object, no progress
    \\  --json      Machine-readable output for one algorithm
    \\  --witness   Include actions (F flag, O open, C chord)
    \\  --quiet     Suppress stderr progress
    \\  --time-limit SECONDS / --max-states N (default 0: unlimited)
    \\Exit: 0 success, 2 exact search limited, 1 invalid input/error.
    \\
;

pub const Algorithm = enum {
    optimal,
    eight_way,
    lzini,
    hzini,

    pub fn label(algorithm: Algorithm) []const u8 {
        return switch (algorithm) {
            .optimal => "optimal",
            .eight_way => "8way",
            .lzini => "lzini",
            .hzini => "hzini",
        };
    }

    fn fromLabel(text: []const u8) ?Algorithm {
        for (std.enums.values(Algorithm)) |algorithm| {
            if (std.mem.eql(u8, text, algorithm.label())) return algorithm;
        }
        return null;
    }
};

pub const RandomSpec = struct {
    width: u32,
    height: u32,
    mines: u32,
    seed: u64,
    /// mt19937_64 with a 64-bit seed instead of mt19937 with a 32-bit one.
    wide: bool,
};

pub const Source = union(enum) {
    /// Always contains a `?` or `&` before its `b=` parameter.
    url: []const u8,
    random: RandomSpec,
};

pub const Algorithms = union(enum) {
    one: Algorithm,
    /// All four, reported in one JSON object.
    all,
};

pub const Config = struct {
    source: Source,
    algorithms: Algorithms,
    json: bool,
    witness: bool,
    log_progress: bool,
    limits: Limits,
};

pub const Command = union(enum) {
    help,
    solve: Config,
};

pub const Diagnostic = struct {
    buffer: [256]u8 = undefined,
    message: []const u8 = "",

    fn fail(d: *Diagnostic, comptime format: []const u8, args: anytype) error{InvalidArguments} {
        d.message = std.fmt.bufPrint(&d.buffer, format, args) catch "Invalid arguments";
        return error.InvalidArguments;
    }
};

pub const ParseError = error{InvalidArguments} || Allocator.Error;

/// `args` excludes the program name. A bare `b=...&m=...` query is accepted.
pub fn parse(arena: Allocator, args: []const []const u8, diag: *Diagnostic) ParseError!Command {
    var raw: RawArgs = .{};
    var cursor: ArgCursor = .{ .args = args, .diag = diag };
    while (cursor.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return .help;
        try raw.accept(arg, &cursor);
    }
    return .{ .solve = try raw.validate(arena, diag) };
}

const ArgCursor = struct {
    args: []const []const u8,
    index: usize = 0,
    diag: *Diagnostic,

    fn next(c: *ArgCursor) ?[]const u8 {
        if (c.index >= c.args.len) return null;
        defer c.index += 1;
        return c.args[c.index];
    }

    fn value(c: *ArgCursor, option: []const u8) error{InvalidArguments}![]const u8 {
        return c.next() orelse c.diag.fail("Missing value for {s}", .{option});
    }

    fn natural(c: *ArgCursor, option: []const u8) error{InvalidArguments}!u64 {
        const text = try c.value(option);
        if (!isDigits(text)) return c.diag.fail("Expected nonnegative integer: {s}", .{text});
        return std.fmt.parseInt(u64, text, 10) catch c.diag.fail("Integer out of range", .{});
    }

    fn integer(c: *ArgCursor, option: []const u8) error{InvalidArguments}!u32 {
        const n = try c.natural(option);
        if (n > std.math.maxInt(i32)) return c.diag.fail("Integer out of range", .{});
        return @intCast(n);
    }
};

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const RawArgs = struct {
    input: ?[]const u8 = null,
    random: ?RandomSpec = null,
    wide_seed: bool = false,
    /// Checked after all arguments, so a later --help still wins.
    algorithm_name: []const u8 = "optimal",
    all: bool = false,
    json: bool = false,
    witness: bool = false,
    quiet: bool = false,
    limits: Limits = .{},

    fn accept(raw: *RawArgs, arg: []const u8, c: *ArgCursor) error{InvalidArguments}!void {
        if (std.mem.eql(u8, arg, "--random")) {
            raw.random = .{
                .width = try c.integer(arg),
                .height = try c.integer(arg),
                .mines = try c.integer(arg),
                .seed = try c.natural(arg),
                .wide = false,
            };
        } else if (std.mem.eql(u8, arg, "--algorithm")) {
            raw.algorithm_name = try c.value(arg);
        } else if (std.mem.eql(u8, arg, "--max-states")) {
            raw.limits.max_states = std.math.cast(usize, try c.natural(arg)) orelse return c.diag.fail("State limit out of range", .{});
        } else if (std.mem.eql(u8, arg, "--time-limit")) {
            raw.limits.time_limit_s = parseSeconds(try c.value(arg)) orelse return c.diag.fail("Invalid time limit", .{});
        } else if (!raw.acceptFlag(arg)) {
            if (std.mem.startsWith(u8, arg, "--")) return c.diag.fail("Unknown option: {s}", .{arg});
            if (raw.input != null) return c.diag.fail("Unexpected argument: {s}", .{arg});
            raw.input = arg;
        }
    }

    fn acceptFlag(raw: *RawArgs, arg: []const u8) bool {
        const flags = .{
            .{ "--64b", "wide_seed" },
            .{ "--all", "all" },
            .{ "--json", "json" },
            .{ "--quiet", "quiet" },
            .{ "--witness", "witness" },
        };
        inline for (flags) |flag| {
            if (std.mem.eql(u8, arg, flag[0])) {
                @field(raw, flag[1]) = true;
                return true;
            }
        }
        return false;
    }

    fn validate(raw: RawArgs, arena: Allocator, diag: *Diagnostic) ParseError!Config {
        const algorithm = Algorithm.fromLabel(raw.algorithm_name) orelse return diag.fail("Unknown algorithm: {s}", .{raw.algorithm_name});
        if (raw.all and algorithm != .optimal) return diag.fail("Choose --all or --algorithm", .{});
        if ((raw.random != null) == (raw.input != null)) return diag.fail("Supply either a URL or --random; see --help", .{});
        if (raw.wide_seed and raw.random == null) return diag.fail("--64b requires --random", .{});
        const source: Source = if (raw.random) |spec| blk: {
            if (!raw.wide_seed and spec.seed > std.math.maxInt(u32)) return diag.fail("Seed out of range", .{});
            var wide = spec;
            wide.wide = raw.wide_seed;
            break :blk .{ .random = wide };
        } else .{ .url = try normalizeUrl(arena, raw.input orelse @panic("Validation lets no command through without a URL or --random")) };
        const json = raw.json or raw.all;
        return .{
            .source = source,
            .algorithms = if (raw.all) .all else .{ .one = algorithm },
            .json = json,
            .witness = raw.witness,
            .log_progress = !raw.quiet and !json,
            .limits = raw.limits,
        };
    }
};

fn parseSeconds(text: []const u8) ?f64 {
    const seconds = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    return seconds;
}

fn normalizeUrl(arena: Allocator, input: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, input, "b=")) return std.fmt.allocPrint(arena, "?{s}", .{input});
    return input;
}
