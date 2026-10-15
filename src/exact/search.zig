//! The layered DP over a schedule
//!
//! Each layer decides one candidate
//! Every state is branched into skip and select,
//! charged for what that decision settles,
//! and deduplicated by its boundary key, keeping the cheapest
//! After every layer each stored key has the smallest cost among all partial choices producing it,
//! so the single state left after the last layer is optimal
//! States that cannot beat the incumbent upper bound are dropped
//! if none remain, the incumbent is optimal
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Objective = model_module.Objective;
const Selection = model_module.Selection;
const schedule_module = @import("schedule.zig");
const Schedule = schedule_module.Schedule;
const packed_search = @import("packed_search.zig");
const reference_search = @import("reference_search.zig");

pub const Limits = struct {
    time_limit_s: f64 = 0,
    max_states: usize = 0,
};

pub const StopReason = enum {
    time_limit,
    state_limit,
    connectivity_too_wide,

    pub fn describe(reason: StopReason) []const u8 {
        return switch (reason) {
            .time_limit => "time limit",
            .state_limit => "state limit",
            .connectivity_too_wide => "connectivity frontier exceeds 254 entries",
        };
    }
};

pub const SearchResult = struct {
    exact: bool = false,
    best: i32,
    chosen: Selection,
    reason: ?StopReason = null,
    peak: usize = 1,
    transitions: usize = 0,
    dominated: usize = 0,
    completed: u32 = 0,
    elapsed: f64 = 0,
};

pub const Stopwatch = struct {
    io: Io,
    started: Io.Timestamp,

    pub fn start(io: Io) Stopwatch {
        return .{ .io = io, .started = .now(io, .awake) };
    }

    pub fn seconds(s: Stopwatch) f64 {
        const elapsed = s.started.untilNow(s.io, .awake);
        return @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
    }

    pub fn exceeded(s: Stopwatch, limits: Limits) bool {
        return limits.time_limit_s > 0 and s.seconds() >= limits.time_limit_s;
    }
};

/// Reads the clock at most once per `interval` transitions
/// A state adds one or two transitions,
/// so the next check is a threshold rather than a multiple of the interval,
/// which could be stepped overs
pub const ClockCheck = struct {
    stopwatch: Stopwatch,
    limits: Limits,
    next: usize,

    const interval = 16384;

    pub fn start(stopwatch: Stopwatch, limits: Limits, transitions: usize) ClockCheck {
        return .{ .stopwatch = stopwatch, .limits = limits, .next = transitions + interval };
    }

    pub fn expired(c: *ClockCheck, transitions: usize) bool {
        if (transitions < c.next) return false;
        c.next = transitions + interval;
        return c.stopwatch.exceeded(c.limits);
    }
};

pub const ProgressLog = struct {
    out: ?*Io.Writer,
    last: f64 = 0,

    pub fn initialBound(log: *ProgressLog, best: i32) void {
        log.writeLine("Initial upper bound: {d}\n", .{best});
    }

    pub fn layer(log: *ProgressLog, completed: u32, total: usize, states: usize, seconds: f64) void {
        if (seconds - log.last < 2) return;
        log.writeLine("DP {d}/{d}: {d} states, {d:.3} s\n", .{ completed, total, states, seconds });
        log.last = seconds;
    }

    fn writeLine(log: *ProgressLog, comptime format: []const u8, args: anytype) void {
        const out = log.out orelse return;
        out.print(format, args) catch return;
        out.flush() catch return;
    }
};

pub const Resources = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    limits: Limits,
    progress: ?*Io.Writer,
    eight_way_chords: []const u32,
};

pub const IncumbentSampler = struct {
    objective: *Objective,
    schedule: SamplingSchedule = .{},
    undecided: []u64,
    completion: Selection,

    pub const sample_size = 128;

    pub fn init(arena: Allocator, objective: *Objective) Allocator.Error!IncumbentSampler {
        const n = objective.model.variableCount();
        const undecided = try arena.alloc(u64, (n + 63) / 64);
        @memset(undecided, std.math.maxInt(u64));
        return .{ .objective = objective, .undecided = undecided, .completion = try Selection.initEmpty(arena, n) };
    }

    pub fn afterLayer(s: *IncumbentSampler, variable: u32, layer: anytype, has_states: bool, final: bool, result: *SearchResult) void {
        s.undecided[variable / 64] &= ~(@as(u64, 1) << @intCast(variable % 64));
        const periodic = s.schedule.due();
        const before = result.best;
        if (has_states and (periodic or final)) layer.sampleCompletions(s, result);
        if (periodic) s.schedule.record(result.best < before);
    }

    pub fn tryCompletion(s: *IncumbentSampler, prefix: []const u64, result: *SearchResult) void {
        for (s.completion.words, result.chosen.words, prefix, s.undecided) |*out, kept, decided, open| {
            out.* = (kept & open) | (decided & ~open);
        }
        const cost = s.objective.cost(s.completion);
        if (cost >= result.best) return;
        result.best = cost;
        result.chosen.copyFrom(s.completion);
    }
};

const SamplingSchedule = struct {
    interval: u32 = base_interval,
    countdown: u32 = base_interval,

    const base_interval = 8;
    const max_interval = 64;

    fn due(s: *SamplingSchedule) bool {
        s.countdown -= 1;
        return s.countdown == 0;
    }

    fn record(s: *SamplingSchedule, improved: bool) void {
        s.interval = if (improved) base_interval else @min(max_interval, s.interval * 2);
        s.countdown = s.interval;
    }
};

pub fn run(r: Resources, m: *const Model, schedule: *const Schedule, objective: *Objective) !SearchResult {
    if (schedule.packed_fits) return packed_search.solve(r, m, schedule, objective);
    return reference_search.solve(r, m, schedule, objective);
}
