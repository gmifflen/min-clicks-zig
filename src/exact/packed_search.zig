//! 16-byte states in `FlatTable`s,
//! connectivity transitions cached per connection id,
//! flags charged on first use,
//! and a target-cover lower bound to cut states that cannot beat the incumbent
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Objective = model_module.Objective;
const Selection = model_module.Selection;
const schedule_module = @import("schedule.zig");
const Schedule = schedule_module.Schedule;
const Step = schedule_module.Step;
const packed_state = @import("packed_state.zig");
const FlatTable = packed_state.FlatTable;
const ConnectionResult = packed_state.ConnectionResult;
const search = @import("search.zig");
const upper_bound = @import("upper_bound.zig");

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
        progress.layer(run.result.completed, m.cells.len, run.states.nodes.items.len, stopwatch.seconds());
        if (run.states.nodes.items.len == 0) {
            run.result.exact = true;
            break;
        }
    }
    if (run.result.completed == m.variableCount()) run.adoptFinalState();
    run.result.elapsed = stopwatch.seconds();
    return run.result;
}

const Run = struct {
    gpa: Allocator,
    objective: *Objective,
    result: search.SearchResult,
    states: FlatTable,
    next: FlatTable,
    cache: std.ArrayList(CacheEntry) = .empty,
    pruning_scratch: std.heap.ArenaAllocator,
    cross_schedule: CrossSchedule,
    sampler: search.IncumbentSampler,

    fn init(r: search.Resources, m: *const Model, objective: *Objective, incumbent: upper_bound.Incumbent) Allocator.Error!Run {
        const n = m.variableCount();
        const words = (n + 63) / 64;
        var run: Run = .{
            .gpa = r.gpa,
            .objective = objective,
            .result = .{ .best = incumbent.best, .chosen = incumbent.chosen },
            .states = .{ .words = words },
            .next = .{ .words = words },
            .pruning_scratch = .init(r.gpa),
            .cross_schedule = .{},
            .sampler = try .init(r.arena, objective),
        };
        errdefer run.deinit();
        const start_connection = try run.states.connections.intern(r.gpa, 0, 0);
        try run.states.insertRoot(r.gpa, start_connection, 0, m.base);
        return run;
    }

    fn deinit(run: *Run) void {
        run.states.deinit(run.gpa);
        run.next.deinit(run.gpa);
        run.cache.deinit(run.gpa);
        run.pruning_scratch.deinit();
    }

    fn decide(run: *Run, st: *const Step, limits: search.Limits, stopwatch: search.Stopwatch) Allocator.Error!?search.StopReason {
        try growCache(run.gpa, &run.cache, run.states.connections.keys.items.len);
        run.next.clear();
        var layer: Layer = .{ .gpa = run.gpa, .st = st, .states = &run.states, .next = &run.next, .cache = run.cache.items, .result = &run.result, .generation = run.result.completed + 1 };
        const stopped = try layer.expand(limits, stopwatch);
        run.result.peak = @max(run.result.peak, run.next.nodes.items.len);
        if (stopped == null) {
            const cross = run.cross_schedule.advance();
            const pruned = try run.next.pruneDominated(&run.pruning_scratch, st, cross);
            run.cross_schedule.record(pruned.cross);
            run.result.dominated += pruned.removed;
        }
        try run.next.materialize(run.gpa, &run.states);
        const is_last = run.result.completed + 1 == run.objective.model.variableCount();
        const sampled: SampledTable = .{ .table = &run.next };
        run.sampler.afterLayer(st.variable, sampled, run.next.nodes.items.len != 0, stopped != null or is_last, &run.result);
        if (stopped != null) return stopped;
        std.mem.swap(FlatTable, &run.states, &run.next);
        run.result.completed += 1;
        return null;
    }

    fn adoptFinalState(run: *Run) void {
        run.result.exact = true;
        if (run.states.nodes.items.len == 0 or run.states.nodes.items[0].cost >= run.result.best) return;
        run.result.best = run.states.nodes.items[0].cost;
        @memcpy(run.result.chosen.words, run.states.choicesOf(0));
    }
};

const CrossSchedule = struct {
    skip: u32 = 0,
    backoff: u32 = 0,

    const max_backoff = 16;
    const work_per_state = 256;

    fn advance(s: *CrossSchedule) bool {
        if (s.skip == 0) return true;
        s.skip -= 1;
        return false;
    }

    fn record(s: *CrossSchedule, cross: ?packed_state.CrossWork) void {
        const done = cross orelse return;
        s.backoff = if (done.removed * work_per_state >= done.work) 1 else @min(max_backoff, @max(2, s.backoff * 2));
        s.skip = s.backoff;
    }
};

const CacheEntry = struct {
    generation: u32 = 0,
    next: [2]ConnectionResult = @splat(.{}),
    target_plus_one: [2]u32 = @splat(0),

    comptime {
        if (@sizeOf(CacheEntry) > 64) @compileError("CacheEntry must stay at most 64 bytes");
    }

    fn target(cached: *CacheEntry, gpa: Allocator, next: *FlatTable, take: bool) Allocator.Error!u32 {
        const slot = &cached.target_plus_one[@intFromBool(take)];
        if (slot.* == 0) {
            const connection = cached.next[@intFromBool(take)];
            slot.* = try next.connections.intern(gpa, connection.lo, connection.hi) + 1;
        }
        return slot.* - 1;
    }
};

fn growCache(gpa: Allocator, cache: *std.ArrayList(CacheEntry), size: usize) Allocator.Error!void {
    const wanted = @max(size, 64);
    if (cache.items.len < wanted) try cache.appendNTimes(gpa, .{}, wanted - cache.items.len);
}

const Layer = struct {
    gpa: Allocator,
    st: *const Step,
    states: *const FlatTable,
    next: *FlatTable,
    cache: []CacheEntry,
    result: *search.SearchResult,
    generation: u32,

    fn expand(layer: *Layer, limits: search.Limits, stopwatch: search.Stopwatch) Allocator.Error!?search.StopReason {
        var clock = search.ClockCheck.start(stopwatch, limits, layer.result.transitions);
        for (layer.states.nodes.items, 0..) |entry, index| {
            const cached = layer.connectionFor(entry.connection);
            for ([_]bool{ false, true }) |take| {
                if (take and layer.isDominatedChord(index)) continue;
                layer.result.transitions += 1;
                try layer.branch(entry, index, cached, take);
                if (limits.max_states != 0 and layer.next.nodes.items.len > limits.max_states) return .state_limit;
            }
            if (clock.expired(layer.result.transitions)) return .time_limit;
        }
        return null;
    }

    fn connectionFor(layer: *Layer, connection: u32) *CacheEntry {
        const cached = &layer.cache[connection];
        if (cached.generation != layer.generation) {
            cached.* = .{
                .generation = layer.generation,
                .next = packed_state.connectionTransitions(layer.states.connections.unpack(connection), layer.st),
            };
        }
        return cached;
    }

    fn isDominatedChord(layer: *const Layer, index: usize) bool {
        const chosen = layer.states.choicesOf(index);
        for (layer.st.chord_dominators) |earlier| {
            if ((chosen[earlier / 64] >> @intCast(earlier % 64)) & 1 != 0) return true;
        }
        return false;
    }

    fn branch(layer: *Layer, entry: FlatTable.Node, index: usize, cached: *CacheEntry, take: bool) Allocator.Error!void {
        const st = layer.st;
        const connection = cached.next[@intFromBool(take)];
        var state = settle(entry, st, connection, take);
        if (state.cost >= layer.result.best) return;
        foldEquivalentFactors(st, &state);
        if (state.cost + lowerBoundOnRest(st, state.factors, connection.live) >= layer.result.best) return;
        const target = try cached.target(layer.gpa, layer.next, take);
        try layer.next.insert(layer.gpa, target, state.factors, state.cost, .{ .parent = @intCast(index), .take = if (take) st.variable else null });
    }
};

const Charged = struct { cost: i32, factors: u64 };

fn settle(entry: FlatTable.Node, st: *const Step, connection: ConnectionResult, take: bool) Charged {
    const factors = entry.factors | (if (take) st.touch_mask else 0);
    const newly_used = factors & ~entry.factors;
    var cost = entry.cost + @intFromBool(take) + @as(i32, connection.seeds) +
        @as(i32, @popCount(newly_used & st.mine_mask)) + @as(i32, @popCount(~factors & st.close_targets));
    for (st.extra_mine_weights) |extra| {
        if (newly_used & extra.mask != 0) cost += extra.weight;
    }
    for (st.extra_target_weights) |extra| {
        if (~factors & extra.mask != 0) cost += extra.weight;
    }
    return .{ .cost = cost, .factors = factors & ~(st.close_mines | st.close_targets) };
}

fn foldEquivalentFactors(st: *const Step, state: *Charged) void {
    for (st.folds) |group| {
        const mines: i32 = @popCount(group.mines & ~state.factors);
        const targets: i32 = @popCount(group.targets & ~state.factors);
        state.cost += @min(mines, targets) * group.weight;
        state.factors = (state.factors | group.mines | group.targets) & ~group.zero_masks[@intCast(mines - targets + group.target_count)];
    }
}

fn lowerBoundOnRest(st: *const Step, factors: u64, live_component: bool) i32 {
    var twelfths = st.bound_constant;
    for (st.bound_masks) |entry| twelfths += @as(i32, @popCount(~factors & entry.mask)) * entry.weight;
    return schedule_module.wholeClicks(twelfths) + @intFromBool(st.future_zero or live_component);
}

const SampledTable = struct {
    table: *const FlatTable,

    pub fn sampleCompletions(sampled: SampledTable, sampler: *search.IncumbentSampler, result: *search.SearchResult) void {
        const nodes = sampled.table.nodes.items;
        var minimum: usize = 0;
        for (nodes, 0..) |node, i| {
            if (node.cost < nodes[minimum].cost) minimum = i;
        }
        sampler.tryCompletion(sampled.table.choicesOf(minimum), result);
        const stride = @max(1, nodes.len / search.IncumbentSampler.sample_size);
        var i: usize = 0;
        while (i < nodes.len) : (i += stride) sampler.tryCompletion(sampled.table.choicesOf(i), result);
    }
};
