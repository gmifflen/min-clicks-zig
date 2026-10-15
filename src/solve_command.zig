//! Runs what a parsed command line asks for:
//! load or generate the board, then run the selected algorithms
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const board_module = @import("board.zig");
const Board = board_module.Board;
const cli = @import("cli.zig");
const action = @import("action.zig");
const HeuristicResult = action.HeuristicResult;
const Recording = action.Recording;
const exact = @import("exact/exact.zig");
const legacy_zini = @import("heuristics/legacy_zini.zig");
const eight_way = @import("heuristics/eight_way.zig");

pub const AllResults = struct {
    exact: exact.ExactResult,
    eight_way: HeuristicResult,
    lzini: HeuristicResult,
    hzini: HeuristicResult,
};

pub const Results = union(enum) {
    exact: exact.ExactResult,
    heuristic: struct { algorithm: cli.Algorithm, result: HeuristicResult },
    all: AllResults,

    pub fn exactResult(r: Results) ?exact.ExactResult {
        return switch (r) {
            .exact => |e| e,
            .all => |a| a.exact,
            .heuristic => null,
        };
    }
};

pub const Solved = struct {
    board: Board,
    results: Results,

    /// 2 when an explicit limit stopped the exact search, else 0.
    pub fn exitCode(s: Solved) u8 {
        const e = s.results.exactResult() orelse return 0;
        return if (e.stats.exact) 0 else 2;
    }
};

pub const SolveError = board_module.DecodeError || board_module.RandomError || Allocator.Error;

/// `gpa` backs the exact search's working tables
/// results live in `arena`
/// The exact search reports progress to `progress` unless it is null
pub fn solve(gpa: Allocator, arena: Allocator, io: Io, config: cli.Config, progress: ?*Io.Writer) SolveError!Solved {
    const board = try loadBoard(arena, config.source);
    const recording: Recording = if (config.witness) .with_actions else .count_only;
    const options: exact.Options = .{ .limits = config.limits, .progress = progress, .include_actions = config.witness };
    const results: Results = switch (config.algorithms) {
        .all => .{ .all = try runAll(gpa, arena, io, &board, options, recording) },
        .one => |algorithm| switch (algorithm) {
            .optimal => .{ .exact = try exact.solveExact(gpa, arena, io, &board, options) },
            .eight_way => .{ .heuristic = .{ .algorithm = algorithm, .result = try eight_way.eightWayZini(arena, &board, recording) } },
            .lzini => .{ .heuristic = .{ .algorithm = algorithm, .result = (try legacy_zini.legacyZini(arena, &board, recording)).lzini } },
            .hzini => .{ .heuristic = .{ .algorithm = algorithm, .result = try legacy_zini.hzini(arena, &board, recording) } },
        },
    };
    return .{ .board = board, .results = results };
}

fn loadBoard(arena: Allocator, source: cli.Source) SolveError!Board {
    return switch (source) {
        .url => |text| board_module.decode(arena, text),
        .random => |spec| if (spec.wide)
            board_module.random64(arena, spec.width, spec.height, spec.mines, spec.seed)
        else
            board_module.random32(arena, spec.width, spec.height, spec.mines, @intCast(spec.seed)),
    };
}

fn runAll(gpa: Allocator, arena: Allocator, io: Io, board: *const Board, options: exact.Options, recording: Recording) SolveError!AllResults {
    const exact_result = try exact.solveExact(gpa, arena, io, board, options);
    const legacy = try legacy_zini.legacyZini(arena, board, recording);
    return .{
        .exact = exact_result,
        .eight_way = try eight_way.eightWayZini(arena, board, recording),
        .lzini = legacy.lzini,
        .hzini = legacy.hzini,
    };
}

pub fn describeError(err: SolveError) []const u8 {
    return switch (err) {
        error.MissingSizeParameter => "URL missing parameter 'b'",
        error.MissingMineParameter => "URL missing parameter 'm'",
        error.InvalidSize => "Invalid board size",
        error.DimensionsOutOfRange => "Board dimensions must be 1..99",
        error.MineEncodingTooShort => "Mine encoding too short",
        error.InvalidMineEncoding => "Invalid base-32 mine encoding",
        error.InvalidBoard => "Invalid board dimensions or mine map",
        error.InvalidRandomParameters => "Invalid random board dimensions/mine count",
        error.OutOfMemory => "Out of memory",
    };
}
