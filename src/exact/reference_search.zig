//! The general DP engine for boundaries too wide for packed keys
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Objective = model_module.Objective;
const Selection = model_module.Selection;
const schedule_module = @import("schedule.zig");
const Schedule = schedule_module.Schedule;
const Step = schedule_module.Step;
const ReferenceTables = schedule_module.ReferenceTables;
const search = @import("search.zig");
const upper_bound = @import("upper_bound.zig");

const max_expanded = 254;

const Entry = struct { cost: i32, chosen: Selection };

const Layer = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    fn reset(layer: *Layer) void {
        layer.map = .empty;
        _ = layer.arena.reset(.retain_capacity);
    }

    pub fn sampleCompletions(layer: *const Layer, sampler: *search.IncumbentSampler, result: *search.SearchResult) void {
        const stride = @max(1, layer.map.count() / search.IncumbentSampler.sample_size);
        var cheapest: ?Entry = null;
        var it = layer.map.iterator();
        var i: usize = 0;
        while (it.next()) |item| : (i += 1) {
            const entry = item.value_ptr.*;
            const cheaper = if (cheapest) |current| entry.cost < current.cost else true;
            if (cheaper) cheapest = entry;
            if (i % stride == 0) sampler.tryCompletion(entry.chosen.words, result);
        }
        if (cheapest) |entry| sampler.tryCompletion(entry.chosen.words, result);
    }
};

pub fn solve(r: search.Resources, m: *const Model, schedule: *const Schedule, objective: *Objective) !search.SearchResult {
    const stopwatch = search.Stopwatch.start(r.io);
    const incumbent = try upper_bound.initialIncumbent(r.arena, objective, r.eight_way_chords);
    var progress: search.ProgressLog = .{ .out = r.progress };
    progress.initialBound(incumbent.best);
    var run = try Run.init(r, m, objective, incumbent);
    defer run.deinit();
    for (schedule.steps) |*st| {
        if (stopwatch.exceeded(r.limits)) {
            run.result.reason = .time_limit;
            break;
        }
        if (try run.decide(st, r.limits, stopwatch)) |reason| {
            run.result.reason = reason;
            break;
        }
        progress.layer(run.result.completed, m.variableCount(), run.states.map.count(), stopwatch.seconds());
        if (run.states.map.count() == 0) {
            run.result.exact = true;
            break;
        }
    }
    if (run.result.completed == m.variableCount()) run.adoptFinalState();
    run.result.elapsed = stopwatch.seconds();
    return run.result;
}

/// The two alternating layers and the incumbent sampler
const Run = struct {
    objective: *Objective,
    result: search.SearchResult,
    states: Layer,
    next: Layer,
    sampler: search.IncumbentSampler,

    fn init(r: search.Resources, m: *const Model, objective: *Objective, incumbent: upper_bound.Incumbent) Allocator.Error!Run {
        var run: Run = .{
            .objective = objective,
            .result = .{ .best = incumbent.best, .chosen = incumbent.chosen },
            .states = .{ .arena = .init(r.gpa) },
            .next = .{ .arena = .init(r.gpa) },
            .sampler = try .init(r.arena, objective),
        };
        errdefer run.deinit();
        const start = run.states.arena.allocator();
        try run.states.map.put(start, "", .{ .cost = m.base, .chosen = try Selection.initEmpty(start, m.variableCount()) });
        return run;
    }

    fn deinit(run: *Run) void {
        run.states.arena.deinit();
        run.next.arena.deinit();
    }

    fn decide(run: *Run, st: *const Step, limits: search.Limits, stopwatch: search.Stopwatch) Allocator.Error!?search.StopReason {
        if (st.expanded.len > max_expanded) return .connectivity_too_wide;
        const tables = st.reference orelse @panic("The reference engine runs only on schedules built with its tables");
        run.next.reset();
        const stopped = try expandLayer(st, tables, &run.states, &run.next, &run.result, limits, stopwatch);
        run.result.peak = @max(run.result.peak, run.next.map.count());
        if (stopped == null) run.result.dominated += try pruneDominated(&run.next, st, tables);
        const is_last = run.result.completed + 1 == run.objective.model.variableCount();
        run.sampler.afterLayer(st.variable, &run.next, run.next.map.count() != 0, stopped != null or is_last, &run.result);
        if (stopped != null) return stopped;
        std.mem.swap(Layer, &run.states, &run.next);
        run.result.completed += 1;
        return null;
    }

    fn adoptFinalState(run: *Run) void {
        run.result.exact = true;
        const final = run.states.map.get("") orelse return;
        if (final.cost >= run.result.best) return;
        run.result.best = final.cost;
        run.result.chosen.copyFrom(final.chosen);
    }
};

fn expandLayer(st: *const Step, tables: ReferenceTables, states: *const Layer, next: *Layer, result: *search.SearchResult, limits: search.Limits, stopwatch: search.Stopwatch) Allocator.Error!?search.StopReason {
    const arena = next.arena.allocator();
    const scratch = try arena.alloc(u8, st.after.len + (st.live_factor_count + 7) / 8);
    var clock = search.ClockCheck.start(stopwatch, limits, result.transitions);
    var it = states.map.iterator();
    while (it.next()) |item| {
        const key = item.key_ptr.*;
        const entry = item.value_ptr.*;
        for ([_]bool{ false, true }) |take| {
            if (take and isDominatedChord(st, entry.chosen)) continue;
            result.transitions += 1;
            const cost = successor(scratch, st, key, entry.cost, take);
            if (cost >= result.best) continue;
            if (cost + lowerBoundOnRest(tables, scratch, st.after.len) >= result.best) continue;
            try keepCheapest(arena, &next.map, scratch, cost, entry.chosen, if (take) st.variable else null);
            if (limits.max_states != 0 and next.map.count() > limits.max_states) return .state_limit;
        }
        if (clock.expired(result.transitions)) return .time_limit;
    }
    return null;
}

fn isDominatedChord(st: *const Step, chosen: Selection) bool {
    for (st.chord_dominators) |earlier| {
        if (chosen.isSet(earlier)) return true;
    }
    return false;
}

fn successor(out: []u8, st: *const Step, key: []const u8, cost_so_far: i32, take: bool) i32 {
    var labels: [256]u8 = @splat(0);
    const highest = expandLabels(&labels, st, key, take);
    @memset(out, 0);
    writeCanonicalLabels(out[0..st.after.len], labels, st);
    return cost_so_far + @intFromBool(take) + finishedComponents(labels, highest, st) +
        settleFactors(out[st.after.len..], key[st.before.len..], st, take);
}

fn expandLabels(labels: *[256]u8, st: *const Step, key: []const u8, take: bool) u8 {
    const old = st.before.len;
    const count = st.expanded.len;
    var highest: u8 = 0;
    for (key[0..old], labels[0..old]) |source, *l| {
        l.* = source;
        highest = @max(highest, source);
    }
    for (labels[old .. count - 1]) |*l| {
        highest += 1;
        l.* = highest;
    }
    if (!take) return highest;
    highest += 1;
    labels[count - 1] = highest;
    for (st.neighbors) |j| {
        const merged = labels[j];
        if (merged == 0) continue;
        for (labels[0..count]) |*l| {
            if (l.* == merged) l.* = highest;
        }
    }
    return highest;
}

fn finishedComponents(labels: [256]u8, highest: u8, st: *const Step) i32 {
    var present: [256]bool = @splat(false);
    var survives: [256]bool = @splat(false);
    for (labels[0..st.expanded.len]) |l| present[l] = true;
    for (st.keep) |j| survives[labels[j]] = true;
    var finished: i32 = 0;
    for (1..@as(usize, highest) + 1) |l| finished += @intFromBool(present[l] and !survives[l]);
    return finished;
}

fn writeCanonicalLabels(out: []u8, labels: [256]u8, st: *const Step) void {
    var rename: [256]u8 = @splat(0);
    var fresh: u8 = 0;
    for (st.keep, out) |source, *slot| {
        const l = labels[source];
        if (l != 0 and rename[l] == 0) {
            fresh += 1;
            rename[l] = fresh;
        }
        slot.* = rename[l];
    }
}

fn settleFactors(out_bits: []u8, old_bits: []const u8, st: *const Step, take: bool) i32 {
    var cost: i32 = 0;
    for (st.factor_updates) |update| {
        const was_used = if (update.old) |b| (old_bits[b / 8] >> @intCast(b % 8)) & 1 != 0 else false;
        const used = (take and update.touches_variable) or was_used;
        switch (update.fate) {
            .closes_mine => cost += if (used) update.weight else 0,
            .closes_target => cost += if (used) 0 else update.weight,
            .stays_at => |b| if (used) {
                out_bits[b / 8] |= @as(u8, 1) << @intCast(b % 8);
            },
        }
    }
    return cost;
}

fn lowerBoundOnRest(tables: ReferenceTables, key: []const u8, after_len: usize) i32 {
    const bits = key[after_len..];
    var flags: i32 = 0;
    for (tables.factors, 0..) |factor, bit| {
        if (factor.mine and isSet(bits, bit)) flags += factor.weight;
    }
    var twelfths = tables.bound_constant;
    for (tables.bound_targets) |target| {
        if (!isSet(bits, target.bit)) twelfths += target.weight;
    }
    const live = std.mem.indexOfNone(u8, key[0..after_len], &.{0}) != null;
    return flags + schedule_module.wholeClicks(twelfths) + @intFromBool(tables.future_zero or live);
}

fn isSet(bits: []const u8, bit: usize) bool {
    return (bits[bit / 8] >> @intCast(bit % 8)) & 1 != 0;
}

fn pruneDominated(layer: *Layer, st: *const Step, tables: ReferenceTables) Allocator.Error!usize {
    const arena = layer.arena.allocator();
    const keys = try arena.alloc([]const u8, layer.map.count());
    const costs = try arena.alloc(i32, keys.len);
    var it = layer.map.iterator();
    var i: usize = 0;
    while (it.next()) |item| : (i += 1) {
        keys[i] = item.key_ptr.*;
        costs[i] = item.value_ptr.cost;
    }
    const order = try arena.alloc(u32, keys.len);
    for (order, 0..) |*o, index| o.* = @intCast(index);
    const grouping: Grouping = .{ .keys = keys, .costs = costs, .connectivity = st.after.len };
    std.mem.sortUnstable(u32, order, grouping, Grouping.lessThan);
    var survivors: std.ArrayList(u32) = .empty;
    var removed: usize = 0;
    for (order, 0..) |index, rank| {
        if (rank == 0 or !grouping.sameConnectivity(order[rank - 1], index)) survivors.clearRetainingCapacity();
        if (dominatedBySurvivor(grouping, tables, index, survivors.items)) {
            _ = layer.map.remove(keys[index]);
            removed += 1;
        } else {
            try survivors.append(arena, index);
        }
    }
    return removed;
}

const Grouping = struct {
    keys: []const []const u8,
    costs: []const i32,
    connectivity: usize,

    fn sameConnectivity(g: Grouping, a: u32, b: u32) bool {
        return std.mem.eql(u8, g.keys[a][0..g.connectivity], g.keys[b][0..g.connectivity]);
    }

    fn lessThan(g: Grouping, a: u32, b: u32) bool {
        switch (std.mem.order(u8, g.keys[a][0..g.connectivity], g.keys[b][0..g.connectivity])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (g.costs[a] != g.costs[b]) return g.costs[a] < g.costs[b];
        return std.mem.order(u8, g.keys[a], g.keys[b]) == .lt;
    }
};

fn dominatedBySurvivor(g: Grouping, tables: ReferenceTables, target: u32, survivors: []const u32) bool {
    for (survivors) |source| {
        if (g.costs[source] + possibleLoss(tables, g.keys[source][g.connectivity..], g.keys[target][g.connectivity..]) <= g.costs[target]) return true;
    }
    return false;
}

fn possibleLoss(tables: ReferenceTables, source: []const u8, target: []const u8) i32 {
    var loss: i32 = 0;
    for (tables.factors, 0..) |factor, bit| {
        const differs = if (factor.mine) isSet(source, bit) and !isSet(target, bit) else isSet(target, bit) and !isSet(source, bit);
        if (differs) loss += factor.weight;
    }
    return loss;
}

fn keepCheapest(arena: Allocator, map: *std.StringHashMapUnmanaged(Entry), key: []const u8, cost: i32, chosen: Selection, take: ?u32) Allocator.Error!void {
    const slot = try map.getOrPut(arena, key);
    if (slot.found_existing) {
        if (cost >= slot.value_ptr.cost) return;
        slot.value_ptr.chosen.copyFrom(chosen);
    } else {
        slot.key_ptr.* = try arena.dupe(u8, key);
        slot.value_ptr.chosen = try chosen.clone(arena);
    }
    slot.value_ptr.cost = cost;
    if (take) |v| slot.value_ptr.chosen.toggle(v);
}
