//! Per-step tables for the DP,
//! precomputed once for a chosen order so the search loops only combine masks and look up indices
//!
//! At step t the DP decides variable `order[t]`
//! The connectivity boundary holds vertices that were already decided (or are zero islands already in reach)
//!  and still have undecided neighbors
//! live factors are those with variables on both sides of the cut
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const order_module = @import("order.zig");
const OrderPlan = order_module.OrderPlan;
const Lifetimes = order_module.Lifetimes;
const packed_state = @import("packed_state.zig");

pub const WeightedMask = struct { mask: u64, weight: i32 };

pub const click_twelfths = 12;

pub fn wholeClicks(twelfths: i32) i32 {
    return @divTrunc(twelfths + click_twelfths - 1, click_twelfths);
}

pub const FactorFold = struct {
    mines: u64 = 0,
    targets: u64 = 0,
    weight: i32,
    target_count: i32 = 0,
    zero_masks: []const u64 = &.{},
};

pub const FactorUpdate = struct {
    old: ?u32,
    touches_variable: bool,
    fate: Fate,
    weight: i32,

    pub const Fate = union(enum) {
        closes_mine,
        closes_target,
        stays_at: u32,
    };
};

pub const Step = struct {
    variable: u32,
    chord_dominators: []const u32 = &.{},
    before: []const u32,
    expanded: []const u32,
    after: []const u32,
    keep: []const u32,
    neighbors: []const u32,
    factor_updates: []const FactorUpdate,
    live_factor_count: u32,
    touch_mask: u64 = 0,
    mine_mask: u64 = 0,
    close_mines: u64 = 0,
    close_targets: u64 = 0,
    extra_mine_weights: []const WeightedMask = &.{},
    extra_target_weights: []const WeightedMask = &.{},
    live_weights: []const WeightedMask = &.{},
    folds: []const FactorFold = &.{},
    bound_constant: i32 = 0,
    bound_masks: []const WeightedMask = &.{},
    future_zero: bool = false,
    reference: ?ReferenceTables = null,
    contacts: []const []const u32 = &.{},
    future_signatures: ?[]const u64 = null,
};

pub const ReferenceTables = struct {
    factors: []const DenseFactor,
    bound_constant: i32,
    bound_targets: []const DenseWeight,
    future_zero: bool,
};

pub const DenseFactor = struct { mine: bool, weight: i32 };
pub const DenseWeight = struct { bit: u32, weight: i32 };

pub const ReferenceTablesWanted = enum { when_needed, always };

pub const Schedule = struct {
    steps: []const Step,
    max_conn: usize = 0,
    max_factors: usize = 0,
    name: []const u8,
    packed_fits: bool,
};

pub fn build(arena: Allocator, gpa: Allocator, m: *const Model, plan: OrderPlan, reference_tables: ReferenceTablesWanted) Allocator.Error!Schedule {
    const pos = try order_module.positions(arena, plan.order);
    const life = try Lifetimes.compute(arena, m, pos);
    const steps = try arena.alloc(Step, plan.order.len);
    var schedule: Schedule = .{ .steps = steps, .name = plan.name, .packed_fits = true };
    var active: []const u32 = &.{};
    var live: []const u32 = &.{};
    for (steps, 0..) |*step, t| {
        step.* = try boundaryStep(arena, m, life, pos, plan.order[@intCast(t)], @intCast(t), active, live);
        live = try liveFactorsAfter(arena, life, @intCast(t), live);
        active = step.after;
        schedule.max_conn = @max(schedule.max_conn, active.len);
        schedule.max_factors = @max(schedule.max_factors, live.len);
        if (step.expanded.len > packed_state.max_expanded_connections or step.after.len > packed_state.max_connections) schedule.packed_fits = false;
    }
    var step_scratch: std.heap.ArenaAllocator = .init(gpa);
    defer step_scratch.deinit();
    if (!try addPackedFactorTables(arena, &step_scratch, m, life, pos, steps)) schedule.packed_fits = false;
    try addChordDominators(arena, m, pos, steps);
    if (reference_tables == .always or !schedule.packed_fits) try addReferenceTables(arena, &step_scratch, m, life, pos, steps);
    return schedule;
}

fn boundaryStep(
    arena: Allocator,
    m: *const Model,
    life: Lifetimes,
    pos: []const u32,
    variable: u32,
    t: u32,
    active: []const u32,
    live_before: []const u32,
) Allocator.Error!Step {
    var expanded: std.ArrayList(u32) = .empty;
    try expanded.appendSlice(arena, active);
    for (life.first[m.variableCount()..], m.variableCount()..) |first, z| {
        if (first == t) try expanded.append(arena, @intCast(z));
    }
    try expanded.append(arena, variable);
    var neighbors: std.ArrayList(u32) = .empty;
    for (expanded.items[0 .. expanded.items.len - 1], 0..) |v, j| {
        if (contains(m.edges[variable], v)) try neighbors.append(arena, @intCast(j));
    }
    var keep: std.ArrayList(u32) = .empty;
    var after: std.ArrayList(u32) = .empty;
    for (expanded.items, 0..) |v, j| {
        if (life.last[v] <= t) continue;
        try keep.append(arena, @intCast(j));
        try after.append(arena, v);
    }
    const factors = try factorUpdates(arena, m, life, variable, t, live_before);
    var step: Step = .{
        .variable = variable,
        .before = active,
        .expanded = expanded.items,
        .after = after.items,
        .keep = keep.items,
        .neighbors = neighbors.items,
        .factor_updates = factors.updates,
        .live_factor_count = factors.live_count,
    };
    if (after.items.len <= packed_state.max_connections) {
        step.contacts = try futureContacts(arena, m, pos, t, after.items);
        step.future_signatures = try contactSignatures(arena, step.contacts);
    }
    return step;
}

const FactorUpdates = struct { updates: []const FactorUpdate, live_count: u32 };

fn factorUpdates(arena: Allocator, m: *const Model, life: Lifetimes, variable: u32, t: u32, live_before: []const u32) Allocator.Error!FactorUpdates {
    var involved: std.ArrayList(u32) = .empty;
    try involved.appendSlice(arena, live_before);
    for (life.factor_first, 0..) |first, f| {
        if (first == t) try involved.append(arena, @intCast(f));
    }
    const updates = try arena.alloc(FactorUpdate, involved.items.len);
    var live_count: u32 = 0;
    for (involved.items, updates) |f, *update| {
        const factor = m.factors[f];
        const closes = life.factor_last[f] == t;
        const fate: FactorUpdate.Fate = if (!closes) .{ .stays_at = live_count } else if (factor.mine) .closes_mine else .closes_target;
        update.* = .{
            .old = indexOf(live_before, f),
            .touches_variable = contains(factor.vars, variable),
            .fate = fate,
            .weight = factor.weight,
        };
        if (!closes) live_count += 1;
    }
    return .{ .updates = updates, .live_count = live_count };
}

fn liveFactorsAfter(arena: Allocator, life: Lifetimes, t: u32, live_before: []const u32) Allocator.Error![]const u32 {
    var live: std.ArrayList(u32) = .empty;
    for (live_before) |f| {
        if (life.factor_last[f] > t) try live.append(arena, f);
    }
    for (life.factor_first, life.factor_last, 0..) |first, last, f| {
        if (first == t and last > t) try live.append(arena, @intCast(f));
    }
    return live.items;
}

fn futureContacts(arena: Allocator, m: *const Model, pos: []const u32, t: u32, after: []const u32) Allocator.Error![]const []const u32 {
    const n = m.variableCount();
    const contacts = try arena.alloc([]const u32, after.len);
    for (after, contacts) |v, *out| {
        var masks: std.ArrayList(u32) = .empty;
        for (m.edges[v]) |u| {
            if (u >= n or pos[u] <= t) continue;
            var mask: u32 = 0;
            for (after, 0..) |w, j| {
                if (contains(m.edges[u], w)) mask |= @as(u32, 1) << @intCast(j);
            }
            try masks.append(arena, mask);
        }
        out.* = masks.items;
    }
    return contacts;
}

fn contactSignatures(arena: Allocator, contacts: []const []const u32) Allocator.Error!?[]const u64 {
    if (contacts.len == 0) return null;
    var patterns: std.ArrayList(u32) = .empty;
    for (contacts) |items| {
        for (items) |mask| {
            if (indexOf(patterns.items, mask) == null) try patterns.append(arena, mask);
        }
    }
    if (patterns.items.len > 64) return null;
    const signatures = try arena.alloc(u64, contacts.len);
    @memset(signatures, 0);
    for (patterns.items, 0..) |pattern, index| {
        var mask = pattern;
        while (mask != 0) : (mask &= mask - 1) signatures[@ctz(mask)] |= @as(u64, 1) << @intCast(index);
    }
    return signatures;
}

fn addPackedFactorTables(arena: Allocator, step_scratch: *std.heap.ArenaAllocator, m: *const Model, life: Lifetimes, pos: []const u32, steps: []Step) Allocator.Error!bool {
    var slots: FactorSlots = try .init(arena, m.factors.len);
    var live_before: []const u32 = &.{};
    for (steps, 0..) |*step, index| {
        const t: u32 = @intCast(index);
        const live_after = try liveFactorsAfter(arena, life, t, live_before);
        const involved = try involvedFactors(arena, m, step.variable, live_before, live_after);
        if (!slots.claim(involved)) return false;
        try setFactorMasks(arena, m, step, involved, live_after, slots);
        _ = step_scratch.reset(.retain_capacity);
        try setTargetCoverBound(arena, step_scratch.allocator(), m, life, pos, t, slots, step);
        step.folds = try factorFolds(arena, step_scratch.allocator(), m, pos, t, live_after, slots);
        step.future_zero = hasFutureZero(m, life, t);
        slots.releaseClosed(involved, live_after);
        live_before = live_after;
    }
    return true;
}

const FactorSlots = struct {
    of: []?u6,
    busy: u64 = 0,

    fn init(arena: Allocator, factor_count: usize) Allocator.Error!FactorSlots {
        const of = try arena.alloc(?u6, factor_count);
        @memset(of, null);
        return .{ .of = of };
    }

    fn claim(s: *FactorSlots, factors: []const u32) bool {
        for (factors) |f| {
            if (s.of[f] != null) continue;
            if (s.busy == std.math.maxInt(u64)) return false;
            const slot: u6 = @intCast(@ctz(~s.busy));
            s.of[f] = slot;
            s.busy |= @as(u64, 1) << slot;
        }
        return true;
    }

    fn bit(s: FactorSlots, f: u32) u64 {
        const slot = s.of[f] orelse @panic("A factor in use has no slot");
        return @as(u64, 1) << slot;
    }

    fn releaseClosed(s: *FactorSlots, involved: []const u32, live_after: []const u32) void {
        for (involved) |f| {
            if (contains(live_after, f)) continue;
            s.busy &= ~s.bit(f);
            s.of[f] = null;
        }
    }
};

fn involvedFactors(arena: Allocator, m: *const Model, variable: u32, live_before: []const u32, live_after: []const u32) Allocator.Error![]const u32 {
    var involved: std.ArrayList(u32) = .empty;
    try involved.appendSlice(arena, live_before);
    for (live_after) |f| {
        if (indexOf(involved.items, f) == null) try involved.append(arena, f);
    }
    for (m.factors, 0..) |factor, f| {
        if (contains(factor.vars, variable) and indexOf(involved.items, @intCast(f)) == null) try involved.append(arena, @intCast(f));
    }
    return involved.items;
}

fn setFactorMasks(arena: Allocator, m: *const Model, step: *Step, involved: []const u32, live_after: []const u32, slots: FactorSlots) Allocator.Error!void {
    var extra_mines: std.ArrayList(WeightedMask) = .empty;
    var extra_targets: std.ArrayList(WeightedMask) = .empty;
    for (involved) |f| {
        const factor = m.factors[f];
        const bit = slots.bit(f);
        if (factor.mine) step.mine_mask |= bit;
        if (factor.mine and factor.weight > 1) try extra_mines.append(arena, .{ .mask = bit, .weight = factor.weight - 1 });
        if (contains(factor.vars, step.variable)) step.touch_mask |= bit;
        if (indexOf(live_after, f) != null) continue;
        if (factor.mine) step.close_mines |= bit else step.close_targets |= bit;
        if (!factor.mine and factor.weight > 1) try extra_targets.append(arena, .{ .mask = bit, .weight = factor.weight - 1 });
    }
    var live_weights: std.ArrayList(WeightedMask) = .empty;
    for (live_after) |f| try live_weights.append(arena, .{ .mask = slots.bit(f), .weight = m.factors[f].weight });
    step.extra_mine_weights = extra_mines.items;
    step.extra_target_weights = extra_targets.items;
    step.live_weights = live_weights.items;
}

fn setTargetCoverBound(arena: Allocator, scratch: Allocator, m: *const Model, life: Lifetimes, pos: []const u32, t: u32, slots: FactorSlots, step: *Step) Allocator.Error!void {
    const dual = try targetCoverDual(scratch, m, life, pos, t);
    var masks: [click_twelfths + 1]u64 = @splat(0);
    for (dual.live_weight, 0..) |weight, f| {
        if (weight != 0) masks[@intCast(weight)] |= slots.bit(@intCast(f));
    }
    var bound_masks: std.ArrayList(WeightedMask) = .empty;
    for (masks[1..], 1..) |mask, weight| {
        if (mask != 0) try bound_masks.append(arena, .{ .mask = mask, .weight = @intCast(weight) });
    }
    step.bound_constant = dual.constant;
    step.bound_masks = bound_masks.items;
}

fn addReferenceTables(arena: Allocator, step_scratch: *std.heap.ArenaAllocator, m: *const Model, life: Lifetimes, pos: []const u32, steps: []Step) Allocator.Error!void {
    var live: []const u32 = &.{};
    for (steps, 0..) |*step, index| {
        const t: u32 = @intCast(index);
        live = try liveFactorsAfter(arena, life, t, live);
        _ = step_scratch.reset(.retain_capacity);
        const factors = try arena.alloc(DenseFactor, live.len);
        for (live, factors) |f, *out| out.* = .{ .mine = m.factors[f].mine, .weight = m.factors[f].weight };
        const dual = try targetCoverDual(step_scratch.allocator(), m, life, pos, t);
        var targets: std.ArrayList(DenseWeight) = .empty;
        for (live, 0..) |f, bit| {
            const weight = dual.live_weight[f];
            if (weight != 0) try targets.append(arena, .{ .bit = @intCast(bit), .weight = weight });
        }
        step.reference = .{ .factors = factors, .bound_constant = dual.constant, .bound_targets = targets.items, .future_zero = hasFutureZero(m, life, t) };
    }
}

const TargetDual = struct {
    constant: i32 = 0,
    live_weight: []const i32,
};

fn targetCoverDual(scratch: Allocator, m: *const Model, life: Lifetimes, pos: []const u32, t: u32) Allocator.Error!TargetDual {
    const PendingTarget = struct { degree: u32, factor: u32 };
    var pending: std.ArrayList(PendingTarget) = .empty;
    for (m.factors, 0..) |factor, f| {
        if (factor.mine or life.factor_last[f] <= t) continue;
        var degree: u32 = 0;
        for (factor.vars) |v| degree += @intFromBool(pos[v] > t);
        try pending.append(scratch, .{ .degree = degree, .factor = @intCast(f) });
    }
    std.mem.sortUnstable(PendingTarget, pending.items, {}, struct {
        fn lessThan(_: void, a: PendingTarget, b: PendingTarget) bool {
            return a.degree < b.degree or (a.degree == b.degree and a.factor < b.factor);
        }
    }.lessThan);
    const capacity = try scratch.alloc(i32, m.cells.len);
    @memset(capacity, click_twelfths);
    const live_weight = try scratch.alloc(i32, m.factors.len);
    @memset(live_weight, 0);
    var dual: TargetDual = .{ .live_weight = live_weight };
    for (pending.items) |entry| {
        const weight = absorbTarget(m.factors[entry.factor].vars, pos, t, capacity);
        if (life.factor_first[entry.factor] > t) dual.constant += weight else live_weight[entry.factor] = weight;
    }
    return dual;
}

fn absorbTarget(vars: []const u32, pos: []const u32, t: u32, capacity: []i32) i32 {
    var weight: i32 = click_twelfths;
    for (vars) |v| {
        if (pos[v] > t) weight = @min(weight, capacity[v]);
    }
    for (vars) |v| {
        if (pos[v] > t) capacity[v] -= weight;
    }
    return weight;
}

fn factorFolds(arena: Allocator, scratch: Allocator, m: *const Model, pos: []const u32, t: u32, live_after: []const u32, slots: FactorSlots) Allocator.Error![]const FactorFold {
    const keyed = try byRemainingScope(scratch, m, pos, t, live_after);
    var folds: std.ArrayList(FactorFold) = .empty;
    var i: usize = 0;
    while (i < keyed.len) {
        var group: FactorFold = .{ .weight = keyed[i].weight };
        var end = i;
        while (end < keyed.len and keyed[end].sameFutureAs(keyed[i])) : (end += 1) {
            const bit = slots.bit(keyed[end].factor);
            if (m.factors[keyed[end].factor].mine) group.mines |= bit else group.targets |= bit;
        }
        i = end;
        if (@popCount(group.mines) + @popCount(group.targets) < 2) continue;
        try completeFold(arena, &group);
        try folds.append(arena, group);
    }
    return folds.items;
}

const RemainingScope = struct {
    scope: []const u32,
    weight: i32,
    factor: u32,

    fn sameFutureAs(a: RemainingScope, b: RemainingScope) bool {
        return a.weight == b.weight and std.mem.eql(u32, a.scope, b.scope);
    }

    fn lessThan(_: void, a: RemainingScope, b: RemainingScope) bool {
        return switch (std.mem.order(u32, a.scope, b.scope)) {
            .lt => true,
            .gt => false,
            .eq => a.weight < b.weight,
        };
    }
};

fn byRemainingScope(scratch: Allocator, m: *const Model, pos: []const u32, t: u32, live_after: []const u32) Allocator.Error![]const RemainingScope {
    const keyed = try scratch.alloc(RemainingScope, live_after.len);
    for (live_after, keyed) |f, *out| {
        var scope: std.ArrayList(u32) = .empty;
        for (m.factors[f].vars) |v| {
            if (pos[v] > t) try scope.append(scratch, v);
        }
        std.mem.sortUnstable(u32, scope.items, {}, std.sort.asc(u32));
        out.* = .{ .scope = scope.items, .weight = m.factors[f].weight, .factor = f };
    }
    std.mem.sortUnstable(RemainingScope, keyed, {}, RemainingScope.lessThan);
    return keyed;
}

fn completeFold(arena: Allocator, group: *FactorFold) Allocator.Error!void {
    const mines: i32 = @popCount(group.mines);
    const targets: i32 = @popCount(group.targets);
    group.target_count = targets;
    const masks = try arena.alloc(u64, @intCast(mines + targets + 1));
    var balance = -targets;
    while (balance <= mines) : (balance += 1) {
        var remaining = if (balance < 0) group.targets else group.mines;
        var zeros: u64 = 0;
        for (0..@abs(balance)) |_| {
            zeros |= remaining & (~remaining +% 1);
            remaining &= remaining - 1;
        }
        masks[@intCast(balance + targets)] = zeros;
    }
    group.zero_masks = masks;
}

fn hasFutureZero(m: *const Model, life: Lifetimes, t: u32) bool {
    const n = m.variableCount();
    for (m.edges[n..], life.first[n..]) |adjacent, first| {
        if (adjacent.len != 0 and first > t) return true;
    }
    return false;
}

fn addChordDominators(arena: Allocator, m: *const Model, pos: []const u32, steps: []Step) Allocator.Error!void {
    const board = m.board;
    const candidate_at = try arena.alloc(?u32, board.cellCount());
    @memset(candidate_at, null);
    for (m.cells, 0..) |cell, i| candidate_at[cell] = @intCast(i);
    for (steps) |*step| {
        const b = m.cells[step.variable];
        var dominators: std.ArrayList(u32) = .empty;
        for (board.neighbors[b].slice()) |neighbor| {
            const a = candidate_at[neighbor] orelse continue;
            if (pos[a] >= pos[step.variable]) continue;
            if (privateSafeSquares(m, m.cells[a], b) <= 1) try dominators.append(arena, a);
        }
        step.chord_dominators = dominators.items;
    }
}

fn privateSafeSquares(m: *const Model, a_cell: u32, b_cell: u32) u32 {
    const board = m.board;
    const a_neighbors = board.neighbors[a_cell].slice();
    var count: u32 = @intFromBool(b_cell != a_cell and !contains(a_neighbors, b_cell));
    for (board.neighbors[b_cell].slice()) |cell| {
        if (board.mine[cell]) continue;
        count += @intFromBool(cell != a_cell and !contains(a_neighbors, cell));
    }
    return count;
}

fn contains(items: []const u32, value: u32) bool {
    return indexOf(items, value) != null;
}

fn indexOf(items: []const u32, value: u32) ?u32 {
    const found = std.mem.indexOfScalar(u32, items, value) orelse return null;
    return @intCast(found);
}
