//! Choosing the order in which the DP decides candidate chords
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_module = @import("model.zig");
const Model = model_module.Model;
const packed_state = @import("packed_state.zig");
const block_order = @import("block_order.zig");
const band_order = @import("band_order.zig");

pub const conn_weight = 300;
pub const factor_weight = 200;
const ratio_weight: f64 = @as(f64, conn_weight) / factor_weight;

pub const OrderPlan = struct {
    order: []const u32,
    name: []const u8,
    score: f64 = 0,
    total_score: f64 = 0,
    max_connections: i32 = 0,
    max_factors: i32 = 0,

    fn fitsPacked(plan: OrderPlan) bool {
        return plan.max_connections <= packed_state.max_connections and plan.max_factors <= packed_state.max_factors;
    }

    fn nearlyFitsPacked(plan: OrderPlan) bool {
        return plan.max_connections <= packed_state.max_connections + 8 and plan.max_factors <= packed_state.max_factors + 16;
    }

    fn isBetterThan(a: OrderPlan, b: OrderPlan) bool {
        return a.score < b.score or (a.score == b.score and a.total_score < b.total_score);
    }
};

const small_search_work = 20_000;
const hard_model_work = 1_000_000;
const refine_min_score = 60;

const other_plain_sweeps = [_]Sweep{
    .{ .axis = .rows },
    .{ .axis = .columns, .reverse = true },
    .{ .axis = .rows, .reverse = true },
};

pub fn choosePlan(arena: Allocator, gpa: Allocator, m: *const Model, whole_board: bool) Allocator.Error!OrderPlan {
    var planning: std.heap.ArenaAllocator = .init(gpa);
    defer planning.deinit();
    const plans = planning.allocator();
    const columns = try planOrder(plans, gpa, m, .{ .axis = .columns });
    const quick = try bestPlainSweep(plans, gpa, m, columns);
    if (quick.total_score < small_search_work) return keepPlan(arena, quick);
    const candidates = try sweepAndBandPlans(plans, gpa, m, columns);
    var raw = columns;
    for (candidates) |candidate| {
        if (candidate.isBetterThan(raw)) raw = candidate;
    }
    const plan = if (raw.score >= refine_min_score) try refineOrder(plans, gpa, m, raw) else raw;
    if (!whole_board or m.cells.len < 250 or raw.total_score < hard_model_work) return keepPlan(arena, plan);
    const alternatives = try withGreedyAlternative(plans, gpa, m, candidates);
    return keepPlan(arena, try preferLessFrontierWork(plans, gpa, m, plan, raw, alternatives));
}

fn keepPlan(arena: Allocator, plan: OrderPlan) Allocator.Error!OrderPlan {
    var kept = plan;
    kept.order = try arena.dupe(u32, plan.order);
    kept.name = try arena.dupe(u8, plan.name);
    return kept;
}

fn bestPlainSweep(plans: Allocator, gpa: Allocator, m: *const Model, columns: OrderPlan) Allocator.Error!OrderPlan {
    var best = columns;
    for (other_plain_sweeps) |sweep| {
        const candidate = try planOrder(plans, gpa, m, sweep);
        if (candidate.isBetterThan(best)) best = candidate;
    }
    return best;
}

fn sweepAndBandPlans(plans: Allocator, gpa: Allocator, m: *const Model, columns: OrderPlan) Allocator.Error![]const OrderPlan {
    var candidates: std.ArrayList(OrderPlan) = .empty;
    try candidates.append(plans, columns);
    for (try candidateSweeps(plans, m)) |sweep| try candidates.append(plans, try planOrder(plans, gpa, m, sweep));
    if (m.cells.len < 64) return candidates.items;
    for (band_order.directions) |direction| try candidates.append(plans, try band_order.dynamicBandOrder(plans, gpa, m, direction));
    return candidates.items;
}

fn withGreedyAlternative(plans: Allocator, gpa: Allocator, m: *const Model, candidates: []const OrderPlan) Allocator.Error![]const OrderPlan {
    var alternatives: std.ArrayList(OrderPlan) = .empty;
    try alternatives.append(plans, candidates[0]);
    try alternatives.append(plans, try greedyFrontierOrder(plans, gpa, m));
    try alternatives.appendSlice(plans, candidates[1..]);
    return alternatives.items;
}

pub fn packedFittingPlan(arena: Allocator, gpa: Allocator, m: *const Model, chosen: OrderPlan) Allocator.Error!?OrderPlan {
    if (!chosen.nearlyFitsPacked()) return null;
    var planning: std.heap.ArenaAllocator = .init(gpa);
    defer planning.deinit();
    const plans = planning.allocator();
    var candidates: std.ArrayList(OrderPlan) = .empty;
    try candidates.append(plans, try planOrder(plans, gpa, m, .{ .axis = .columns }));
    for (try candidateSweeps(plans, m)) |sweep| try candidates.append(plans, try planOrder(plans, gpa, m, sweep));
    for (band_order.directions) |direction| try candidates.append(plans, try band_order.dynamicBandOrder(plans, gpa, m, direction));
    try candidates.append(plans, try greedyFrontierOrder(plans, gpa, m));
    std.mem.sortUnstable(OrderPlan, candidates.items, {}, struct {
        fn lessThan(_: void, a: OrderPlan, b: OrderPlan) bool {
            return a.isBetterThan(b);
        }
    }.lessThan);
    for (candidates.items) |candidate| {
        if (candidate.fitsPacked()) return try keepPlan(arena, candidate);
    }
    var refined: usize = 0;
    for (candidates.items) |candidate| {
        if (refined == 2) break;
        if (!candidate.nearlyFitsPacked()) continue;
        refined += 1;
        const plan = try refineOrder(plans, gpa, m, candidate);
        if (plan.fitsPacked()) return try keepPlan(arena, plan);
    }
    return null;
}

fn candidateSweeps(arena: Allocator, m: *const Model) Allocator.Error![]const Sweep {
    var sweeps: std.ArrayList(Sweep) = .empty;
    try sweeps.appendSlice(arena, &other_plain_sweeps);
    const b = m.board;
    if (b.height <= b.width) try appendStripSweeps(arena, &sweeps, .columns);
    if (b.width <= b.height) try appendStripSweeps(arena, &sweeps, .rows);
    return sweeps.items;
}

fn appendStripSweeps(arena: Allocator, sweeps: *std.ArrayList(Sweep), axis: Sweep.Axis) Allocator.Error!void {
    try sweeps.appendSlice(arena, &.{
        .{ .axis = axis, .strip_band = 1 },
        .{ .axis = axis, .strip_band = 1, .reverse = true },
        .{ .axis = axis, .strip_band = 2 },
        .{ .axis = axis, .strip_band = 2, .reverse = true },
    });
}

fn preferLessFrontierWork(plans: Allocator, gpa: Allocator, m: *const Model, plan: OrderPlan, raw: OrderPlan, alternatives: []const OrderPlan) Allocator.Error!OrderPlan {
    const Ranked = struct { work: f64, index: usize };
    var ranked: std.ArrayList(Ranked) = .empty;
    for (alternatives, 0..) |alternative, i| {
        if (std.mem.eql(u32, alternative.order, raw.order) or alternative.total_score > raw.total_score * 1.2) continue;
        try ranked.append(plans, .{ .work = try estimateFrontierWork(gpa, m, alternative), .index = i });
    }
    if (ranked.items.len == 0) return plan;
    std.mem.sortUnstable(Ranked, ranked.items, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            return a.work < b.work or (a.work == b.work and a.index < b.index);
        }
    }.lessThan);
    var best: Estimated = .{ .plan = plan, .work = try estimateFrontierWork(gpa, m, plan) };
    for (ranked.items[0..@min(2, ranked.items.len)]) |entry| {
        const candidate = try withRefinementIfCheaper(plans, gpa, m, .{ .plan = alternatives[entry.index], .work = entry.work });
        if (candidate.work < best.work * 0.95) best = candidate;
    }
    return best.plan;
}

const Estimated = struct { plan: OrderPlan, work: f64 };

fn withRefinementIfCheaper(plans: Allocator, gpa: Allocator, m: *const Model, estimated: Estimated) Allocator.Error!Estimated {
    if (estimated.plan.score < refine_min_score) return estimated;
    const refined = try refineOrder(plans, gpa, m, estimated.plan);
    const refined_work = try estimateFrontierWork(gpa, m, refined);
    return if (refined_work < estimated.work) .{ .plan = refined, .work = refined_work } else estimated;
}

fn greedyFrontierOrder(plans: Allocator, gpa: Allocator, m: *const Model) Allocator.Error!OrderPlan {
    var greedy = try FrontierGreedy.init(plans, m);
    const order = try plans.alloc(u32, m.cells.len);
    for (order) |*slot| {
        slot.* = greedy.cheapestNext();
        try greedy.decide(plans, slot.*);
    }
    return scoreOrder(gpa, m, order, "greedy-frontier", null);
}

const FrontierGreedy = struct {
    m: *const Model,
    reached: []bool,
    open: []u32,
    undecided_in: []u32,
    factors_of: []const []const u32,
    frontier: std.ArrayList(u32) = .empty,
    on_frontier: []bool,
    by_sweep: []const u32,
    sweep_rank: []const u32,
    next_in_sweep: usize = 0,

    const conn_units = 3;
    const factor_units = 2;

    fn init(plans: Allocator, m: *const Model) Allocator.Error!FrontierGreedy {
        const n = m.variableCount();
        const by_sweep = try plans.alloc(u32, n);
        for (by_sweep, 0..) |*v, i| v.* = @intCast(i);
        std.mem.sortUnstable(u32, by_sweep, SweepKey{ .m = m, .sweep = .{ .axis = .columns } }, SweepKey.lessThan);
        const greedy: FrontierGreedy = .{
            .m = m,
            .reached = try plans.alloc(bool, m.edges.len),
            .open = try plans.alloc(u32, m.edges.len),
            .undecided_in = try plans.alloc(u32, m.factors.len),
            .factors_of = try model_module.factorsByVariable(plans, m),
            .on_frontier = try plans.alloc(bool, n),
            .by_sweep = by_sweep,
            .sweep_rank = try positions(plans, by_sweep),
        };
        @memset(greedy.reached, false);
        @memset(greedy.on_frontier, false);
        for (m.edges, greedy.open) |adjacent, *open| {
            open.* = 0;
            for (adjacent) |u| open.* += @intFromBool(u < n);
        }
        for (m.factors, greedy.undecided_in) |factor, *count| count.* = @intCast(factor.vars.len);
        return greedy;
    }

    const Choice = struct { v: u32, change: i32 };

    fn cheapestNext(g: *FrontierGreedy) u32 {
        var best: ?Choice = null;
        var i: usize = 0;
        while (i < g.frontier.items.len) {
            const v = g.frontier.items[i];
            if (g.reached[v]) {
                _ = g.frontier.swapRemove(i);
                continue;
            }
            i += 1;
            const choice: Choice = .{ .v = v, .change = g.widthChange(v) };
            const better = if (best) |current| g.prefers(choice, current) else true;
            if (better) best = choice;
        }
        if (best) |choice| return choice.v;
        while (g.reached[g.by_sweep[g.next_in_sweep]]) g.next_in_sweep += 1;
        return g.by_sweep[g.next_in_sweep];
    }

    fn prefers(g: *const FrontierGreedy, a: Choice, b: Choice) bool {
        if (a.change != b.change) return a.change < b.change;
        return g.sweep_rank[a.v] < g.sweep_rank[b.v];
    }

    fn widthChange(g: *const FrontierGreedy, v: u32) i32 {
        const n = g.m.variableCount();
        var change: i32 = if (g.open[v] > 0) conn_units else 0;
        for (g.m.edges[v]) |u| {
            const entering = u >= n and !g.reached[u];
            if (entering and g.open[u] > 1) change += conn_units;
            if (g.reached[u] and g.open[u] == 1) change -= conn_units;
        }
        for (g.factors_of[v]) |f| {
            const started = g.undecided_in[f] < g.m.factors[f].vars.len;
            if (!started and g.undecided_in[f] > 1) change += factor_units;
            if (started and g.undecided_in[f] == 1) change -= factor_units;
        }
        return change;
    }

    fn decide(g: *FrontierGreedy, plans: Allocator, v: u32) Allocator.Error!void {
        g.reached[v] = true;
        for (g.m.edges[v]) |u| {
            g.open[u] -= 1;
            try g.addToFrontier(plans, u);
            if (u < g.m.variableCount() or g.reached[u]) continue;
            g.reached[u] = true;
            for (g.m.edges[u]) |w| try g.addToFrontier(plans, w);
        }
        for (g.factors_of[v]) |f| {
            g.undecided_in[f] -= 1;
            for (g.m.factors[f].vars) |w| try g.addToFrontier(plans, w);
        }
    }

    fn addToFrontier(g: *FrontierGreedy, plans: Allocator, v: u32) Allocator.Error!void {
        if (v >= g.m.variableCount() or g.reached[v] or g.on_frontier[v]) return;
        g.on_frontier[v] = true;
        try g.frontier.append(plans, v);
    }
};

pub const Sweep = struct {
    axis: Axis,
    reverse: bool = false,
    strip_band: u8 = 0,

    pub const Axis = enum { rows, columns };

    fn name(s: Sweep, arena: Allocator) Allocator.Error![]const u8 {
        const band = switch (s.strip_band) {
            0 => "",
            1 => "-dp",
            else => "-dp2",
        };
        return std.fmt.allocPrint(arena, "{t}{s}{s}", .{ s.axis, band, if (s.reverse) "-reverse" else "" });
    }
};

fn planOrder(plans: Allocator, gpa: Allocator, m: *const Model, sweep: Sweep) Allocator.Error!OrderPlan {
    const order = try plans.alloc(u32, m.cells.len);
    for (order, 0..) |*v, i| v.* = @intCast(i);
    const context: SweepKey = .{ .m = m, .sweep = sweep };
    std.mem.sortUnstable(u32, order, context, SweepKey.lessThan);
    if (sweep.strip_band != 0) try block_order.optimizeStrips(gpa, m, order, sweep.axis == .rows, sweep.strip_band);
    return scoreOrder(gpa, m, order, try sweep.name(plans), null);
}

const SweepKey = struct {
    m: *const Model,
    sweep: Sweep,

    fn key(k: SweepKey, v: u32) u32 {
        const b = k.m.board;
        const p = k.m.cells[v];
        return if (k.sweep.axis == .rows) p else (p % b.width) * b.height + p / b.width;
    }

    fn lessThan(k: SweepKey, a: u32, b: u32) bool {
        return if (k.sweep.reverse) k.key(a) > k.key(b) else k.key(a) < k.key(b);
    }
};

fn refineOrder(plans: Allocator, gpa: Allocator, m: *const Model, start: OrderPlan) Allocator.Error!OrderPlan {
    const name = try std.fmt.allocPrint(plans, "{s}-w", .{start.name});
    var plan = start;
    for (0..4) |pass| {
        const order = try plans.dupe(u32, plan.order);
        try block_order.optimizeWindows(gpa, m, order, 16, (pass % 2) * 8);
        const candidate = try scoreOrder(gpa, m, order, name, null);
        if (candidate.isBetterThan(plan)) plan = candidate;
    }
    return plan;
}

pub const Range = struct { begin: usize, end: usize };

pub fn scoreOrder(gpa: Allocator, m: *const Model, order: []const u32, name: []const u8, range: ?Range) Allocator.Error!OrderPlan {
    const n = order.len;
    const pos = try positions(gpa, order);
    defer gpa.free(pos);
    const life = try Lifetimes.compute(gpa, m, pos);
    defer life.deinit(gpa);
    const conn_delta = try gpa.alloc(i32, n + 1);
    defer gpa.free(conn_delta);
    const factor_delta = try gpa.alloc(i32, n + 1);
    defer gpa.free(factor_delta);
    @memset(conn_delta, 0);
    @memset(factor_delta, 0);
    Lifetimes.addSpanDeltas(life.first, life.last, conn_delta);
    Lifetimes.addSpanDeltas(life.factor_first, life.factor_last, factor_delta);
    const measured = range orelse Range{ .begin = 0, .end = n };
    var plan: OrderPlan = .{ .order = order, .name = name };
    var connections: i32 = 0;
    var factors: i32 = 0;
    for (0..n) |t| {
        connections += conn_delta[t];
        factors += factor_delta[t];
        if (t < measured.begin or t >= measured.end) continue;
        const width = ratio_weight * @as(f64, @floatFromInt(connections)) + @as(f64, @floatFromInt(factors));
        plan.score = @max(plan.score, width);
        plan.total_score += @exp2(width / 4);
        plan.max_connections = @max(plan.max_connections, connections);
        plan.max_factors = @max(plan.max_factors, factors);
    }
    return plan;
}

pub fn positions(arena: Allocator, order: []const u32) Allocator.Error![]u32 {
    const pos = try arena.alloc(u32, order.len);
    for (order, 0..) |v, t| pos[v] = @intCast(t);
    return pos;
}

pub const Lifetimes = struct {
    first: []i32,
    last: []i32,
    factor_first: []i32,
    factor_last: []i32,
    vertex_storage: []i32,
    factor_storage: []i32,

    pub fn compute(allocator: Allocator, m: *const Model, pos: []const u32) Allocator.Error!Lifetimes {
        const n = m.variableCount();
        const vertices = try allocator.alloc(i32, 2 * m.edges.len);
        errdefer allocator.free(vertices);
        const factors = try allocator.alloc(i32, 2 * m.factors.len);
        const life: Lifetimes = .{
            .first = vertices[0..m.edges.len],
            .last = vertices[m.edges.len..],
            .factor_first = factors[0..m.factors.len],
            .factor_last = factors[m.factors.len..],
            .vertex_storage = vertices,
            .factor_storage = factors,
        };
        for (m.edges, 0..) |adjacent, i| {
            const span = decisionSpan(adjacent, pos, n);
            if (i < n) {
                life.first[i] = @intCast(pos[i]);
                life.last[i] = @max(span.last, life.first[i]);
            } else {
                life.first[i] = span.first;
                life.last[i] = span.last;
            }
        }
        for (m.factors, 0..) |factor, f| {
            const span = decisionSpan(factor.vars, pos, n);
            life.factor_first[f] = span.first;
            life.factor_last[f] = span.last;
        }
        return life;
    }

    const Span = struct { first: i32, last: i32 };

    fn decisionSpan(vertices: []const u32, pos: []const u32, n: u32) Span {
        var span: Span = .{ .first = @intCast(n), .last = -1 };
        for (vertices) |v| {
            if (v >= n) continue;
            span.first = @min(span.first, @as(i32, @intCast(pos[v])));
            span.last = @max(span.last, @as(i32, @intCast(pos[v])));
        }
        return span;
    }

    pub fn deinit(life: Lifetimes, allocator: Allocator) void {
        allocator.free(life.vertex_storage);
        allocator.free(life.factor_storage);
    }

    fn addSpanDeltas(first: []const i32, last: []const i32, delta: []i32) void {
        for (first, last) |f, l| {
            if (f >= l) continue;
            delta[@intCast(f)] += 1;
            delta[@intCast(l)] -= 1;
        }
    }
};

fn estimateFrontierWork(gpa: Allocator, m: *const Model, plan: OrderPlan) Allocator.Error!f64 {
    const n = plan.order.len;
    const pos = try positions(gpa, plan.order);
    defer gpa.free(pos);
    const life = try Lifetimes.compute(gpa, m, pos);
    defer life.deinit(gpa);
    const conn_delta = try gpa.alloc(i32, n + 1);
    defer gpa.free(conn_delta);
    @memset(conn_delta, 0);
    Lifetimes.addSpanDeltas(life.first, life.last, conn_delta);
    const decisions = try gpa.alloc(u64, n);
    defer gpa.free(decisions);
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);
    var work: f64 = 0;
    var connections: i32 = 0;
    for (0..n) |t| {
        connections += conn_delta[t];
        active.clearRetainingCapacity();
        for (life.factor_first, life.factor_last, 0..) |first, last, f| {
            if (first <= t and t < last) try active.append(gpa, @intCast(f));
        }
        const rank = liveFactorRank(m, pos, active.items, decisions[0 .. t + 1]);
        work += @exp2((ratio_weight * @as(f64, @floatFromInt(connections)) + @as(f64, @floatFromInt(rank))) / 4);
    }
    return work;
}

fn liveFactorRank(m: *const Model, pos: []const u32, active: []const u32, decisions: []u64) usize {
    if (active.len > 64) return active.len;
    @memset(decisions, 0);
    for (active, 0..) |f, bit| {
        for (m.factors[f].vars) |v| {
            if (pos[v] < decisions.len) decisions[pos[v]] |= @as(u64, 1) << @intCast(bit);
        }
    }
    var basis: [64]u64 = @splat(0);
    var rank: usize = 0;
    for (decisions) |decision| {
        var mask = decision;
        while (mask != 0) {
            const top: usize = 63 - @clz(mask);
            if (basis[top] == 0) {
                basis[top] = mask;
                rank += 1;
                break;
            }
            mask ^= basis[top];
        }
    }
    return rank;
}
