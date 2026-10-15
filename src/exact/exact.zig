//! The exact minimum-clicks solver
//! reduce the candidates, split independent pieces,
//! plan an order for each, and run the DP
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Board = @import("../board.zig").Board;
const Action = @import("../action.zig").Action;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Objective = model_module.Objective;
const Selection = model_module.Selection;
const Breakdown = model_module.Breakdown;
const order_module = @import("order.zig");
const schedule_module = @import("schedule.zig");
const search = @import("search.zig");
const decompose = @import("decompose.zig");
const reduce = @import("reduce.zig");
const witness_module = @import("witness.zig");
const eight_way = @import("../heuristics/eight_way.zig");

pub const Limits = search.Limits;
pub const StopReason = search.StopReason;

pub const Options = struct {
    limits: Limits = .{},
    progress: ?*Io.Writer = null,
    include_actions: bool = true,
};

pub const Engine = enum { @"packed", reference };

pub const SearchStats = struct {
    exact: bool = true,
    clicks: i32 = 0,
    reason: ?StopReason = null,
    peak: usize = 0,
    transitions: usize = 0,
    dominated: usize = 0,
    completed: u32 = 0,
    max_conn: usize = 0,
    max_factors: usize = 0,
    elapsed: f64 = 0,
    order: []const u8,
    engine: Engine = .@"packed",
};

pub const ExactResult = struct {
    stats: SearchStats,
    breakdown: Breakdown,
    actions: []const Action,
    candidates: u32,
    removed: i32,
};

pub fn solveExact(gpa: Allocator, arena: Allocator, io: Io, board: *const Board, options: Options) !ExactResult {
    const m = if (board.cellCount() <= 81) try model_module.build(arena, board) else try reduce.reduceCandidates(arena, gpa, board);
    var parts = try decompose.independentParts(arena, &m);
    if (parts.len == 2 and m.cells.len > 150) parts = &.{};
    const resources: search.Resources = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .limits = options.limits,
        .progress = options.progress,
        .eight_way_chords = try eightWayChords(arena, board),
    };
    const outcome = if (parts.len <= 1) try solveWhole(resources, &m) else try solvePieces(resources, &m, parts);

    const breakdown = try model_module.breakdown(arena, &m, outcome.chosen);
    if (breakdown.total() != outcome.stats.clicks) @panic("Internal objective mismatch");
    var actions: []const Action = &.{};
    if (options.include_actions) {
        actions = try witness_module.witness(arena, &m, outcome.chosen);
        if (actions.len != outcome.stats.clicks) @panic("Internal witness cost mismatch");
    }
    return .{ .stats = outcome.stats, .breakdown = breakdown, .actions = actions, .candidates = m.variableCount(), .removed = m.removed };
}

fn eightWayChords(arena: Allocator, board: *const Board) Allocator.Error![]const u32 {
    var cells: std.ArrayList(u32) = .empty;
    for ((try eight_way.eightWayZini(arena, board, .with_actions)).actions) |a| {
        if (a.kind == .chord) try cells.append(arena, a.cell);
    }
    return cells.items;
}

const Outcome = struct { stats: SearchStats, chosen: Selection };

fn solveWhole(r: search.Resources, m: *const Model) !Outcome {
    var objective = try Objective.init(r.arena, m);
    const solved = try solveModel(r, m, &objective, true);
    const s = solved.result;
    return .{
        .chosen = s.chosen,
        .stats = .{
            .exact = s.exact,
            .clicks = s.best,
            .reason = s.reason,
            .peak = s.peak,
            .transitions = s.transitions,
            .dominated = s.dominated,
            .completed = s.completed,
            .max_conn = solved.schedule.max_conn,
            .max_factors = solved.schedule.max_factors,
            .elapsed = s.elapsed,
            .order = solved.schedule.name,
            .engine = if (solved.schedule.packed_fits) .@"packed" else .reference,
        },
    };
}

fn solvePieces(r: search.Resources, m: *const Model, parts: []const []const u32) !Outcome {
    const pieces = try r.arena.alloc(Model, parts.len);
    const objectives = try r.arena.alloc(Objective, parts.len);
    const costs = try r.arena.alloc(i32, parts.len);
    var zero_copies: i32 = 0;
    for (parts, pieces, objectives, costs) |vars, *piece, *objective, *cost| {
        piece.* = try model_module.piece(r.arena, m, vars);
        zero_copies += @intCast(piece.edges.len - piece.cells.len);
        objective.* = try Objective.init(r.arena, piece);
        cost.* = objective.cost(try Selection.initEmpty(r.arena, vars.len));
    }
    const nonisolated_zeros: i32 = @as(i32, @intCast(m.edges.len - m.cells.len)) - m.isolated_zeros;
    var best = m.base - (zero_copies - nonisolated_zeros);
    for (costs) |cost| best += cost;

    var stats: SearchStats = .{ .order = try std.fmt.allocPrint(r.arena, "components({d})", .{pieces.len}) };
    const chosen = try Selection.initEmpty(r.arena, m.cells.len);
    for (pieces, parts, objectives, costs) |*piece, vars, *objective, *cost| {
        var local = r;
        if (r.limits.time_limit_s > 0) local.limits.time_limit_s = @max(1e-9, r.limits.time_limit_s - stats.elapsed);
        const solved = try solveModel(local, piece, objective, false);
        const s = solved.result;
        best += s.best - cost.*;
        cost.* = s.best;
        for (vars, 0..) |v, local_index| {
            if (s.chosen.isSet(@intCast(local_index))) chosen.toggle(v);
        }
        accumulatePiece(&stats, solved);
        if (!s.exact) {
            stats.exact = false;
            stats.reason = s.reason;
            break;
        }
    }
    stats.clicks = best;
    return .{ .stats = stats, .chosen = chosen };
}

fn accumulatePiece(stats: *SearchStats, solved: Solved) void {
    const s = solved.result;
    const schedule = solved.schedule;
    stats.peak = @max(stats.peak, s.peak);
    stats.transitions += s.transitions;
    stats.dominated += s.dominated;
    stats.completed += s.completed;
    stats.elapsed += s.elapsed;
    stats.max_conn = @max(stats.max_conn, schedule.max_conn);
    stats.max_factors = @max(stats.max_factors, schedule.max_factors);
    if (!schedule.packed_fits) stats.engine = .reference;
}

const Solved = struct {
    result: search.SearchResult,
    schedule: schedule_module.Schedule,
};

fn solveModel(r: search.Resources, m: *const Model, objective: *Objective, whole_board: bool) Allocator.Error!Solved {
    const plan = try order_module.choosePlan(r.arena, r.gpa, m, whole_board);
    var schedule = try schedule_module.build(r.arena, r.gpa, m, plan, .when_needed);
    if (!schedule.packed_fits) schedule = try packedFittingSchedule(r, m, plan) orelse schedule;
    return .{ .result = try search.run(r, m, &schedule, objective), .schedule = schedule };
}

fn packedFittingSchedule(r: search.Resources, m: *const Model, current: order_module.OrderPlan) Allocator.Error!?schedule_module.Schedule {
    const plan = try order_module.packedFittingPlan(r.arena, r.gpa, m, current) orelse return null;
    const schedule = try schedule_module.build(r.arena, r.gpa, m, plan, .when_needed);
    return if (schedule.packed_fits) schedule else null;
}
