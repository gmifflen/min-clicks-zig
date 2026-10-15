//! Band sweeps whose band boundaries are themselves chosen
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const order_module = @import("order.zig");
const OrderPlan = order_module.OrderPlan;

const max_band_lines = 8;

pub const Direction = struct { rows: bool, reverse: bool };

pub const directions = [_]Direction{
    .{ .rows = false, .reverse = false },
    .{ .rows = false, .reverse = true },
    .{ .rows = true, .reverse = false },
    .{ .rows = true, .reverse = true },
};

pub fn dynamicBandOrder(plans: Allocator, gpa: Allocator, m: *const Model, direction: Direction) Allocator.Error!OrderPlan {
    const lines: usize = if (direction.rows) m.board.height else m.board.width;
    const geometry: BandGeometry = .{ .m = m, .rows = direction.rows, .reverse = direction.reverse, .lines = lines };
    const by_line = try geometry.variablesByLine(plans);
    const bands = try bandProfiles(plans, gpa, m, geometry, by_line);
    const peak = try lowestBandPeak(plans, bands, lines, geometry.maxBand());
    const previous = try cheapestBanding(plans, bands, lines, geometry.maxBand(), peak);

    var order: std.ArrayList(u32) = .empty;
    var name: std.ArrayList(u8) = .empty;
    try name.print(plans, "{s}{s}b", .{ if (direction.rows) "r" else "c", if (direction.reverse) "r" else "" });
    const splits = try bandSplits(plans, previous, lines);
    for (splits) |split| {
        try order.appendSlice(plans, bands[split.start][split.end - split.start - 1].order);
        try name.print(plans, "-{d}", .{split.end - split.start});
    }
    return order_module.scoreOrder(gpa, m, order.items, name.items, null);
}

const BandGeometry = struct {
    m: *const Model,
    rows: bool,
    reverse: bool,
    lines: usize,

    fn maxBand(g: BandGeometry) usize {
        return @min(g.lines, max_band_lines);
    }

    fn line(g: BandGeometry, v: u32) usize {
        const cell = g.m.cells[v];
        const physical: usize = if (g.rows) cell / g.m.board.width else cell % g.m.board.width;
        return if (g.reverse) g.lines - 1 - physical else physical;
    }

    fn secondary(g: BandGeometry, v: u32) usize {
        const cell = g.m.cells[v];
        return if (g.rows) cell % g.m.board.width else cell / g.m.board.width;
    }

    fn lessThan(g: BandGeometry, a: u32, b: u32) bool {
        const sa = g.secondary(a);
        const sb = g.secondary(b);
        return sa < sb or (sa == sb and g.line(a) < g.line(b));
    }

    fn variablesByLine(g: BandGeometry, arena: Allocator) Allocator.Error![]const []const u32 {
        const lists = try arena.alloc(std.ArrayList(u32), g.lines);
        @memset(lists, .empty);
        for (0..g.m.cells.len) |v| try lists[g.line(@intCast(v))].append(arena, @intCast(v));
        const result = try arena.alloc([]const u32, g.lines);
        for (result, lists) |*out, list| out.* = list.items;
        return result;
    }
};

fn bandProfiles(plans: Allocator, gpa: Allocator, m: *const Model, g: BandGeometry, by_line: []const []const u32) Allocator.Error![]const []const OrderPlan {
    const max_band = g.maxBand();
    const prefix = try plans.alloc(usize, g.lines + 1);
    prefix[0] = 0;
    for (by_line, 0..) |members, l| prefix[l + 1] = prefix[l] + members.len;
    const bands = try plans.alloc([]OrderPlan, g.lines);
    var trial: std.ArrayList(u32) = .empty;
    defer trial.deinit(gpa);
    for (bands, 0..) |*row, start| {
        const last_end = @min(g.lines, start + max_band);
        row.* = try plans.alloc(OrderPlan, last_end - start);
        for (start + 1..last_end + 1) |end| {
            var inside: std.ArrayList(u32) = .empty;
            for (by_line[start..end]) |members| try inside.appendSlice(plans, members);
            std.mem.sortUnstable(u32, inside.items, g, BandGeometry.lessThan);
            trial.clearRetainingCapacity();
            for (by_line[0..start]) |members| try trial.appendSlice(gpa, members);
            try trial.appendSlice(gpa, inside.items);
            for (by_line[end..]) |members| try trial.appendSlice(gpa, members);
            var profile = try order_module.scoreOrder(gpa, m, trial.items, "", .{ .begin = prefix[start], .end = prefix[end] });
            profile.order = inside.items;
            row.*[end - start - 1] = profile;
        }
    }
    return bands;
}

fn lowestBandPeak(arena: Allocator, bands: []const []const OrderPlan, lines: usize, max_band: usize) Allocator.Error!f64 {
    const peak = try arena.alloc(f64, lines + 1);
    @memset(peak, std.math.inf(f64));
    peak[0] = 0;
    for (1..lines + 1) |end| {
        for (end -| max_band..end) |start| {
            peak[end] = @min(peak[end], @max(peak[start], bands[start][end - start - 1].score));
        }
    }
    return peak[lines];
}

fn cheapestBanding(arena: Allocator, bands: []const []const OrderPlan, lines: usize, max_band: usize, peak: f64) Allocator.Error![]const ?usize {
    const work = try arena.alloc(f64, lines + 1);
    const previous = try arena.alloc(?usize, lines + 1);
    @memset(work, std.math.inf(f64));
    @memset(previous, null);
    work[0] = 0;
    for (1..lines + 1) |end| {
        for (end -| max_band..end) |start| {
            const band = bands[start][end - start - 1];
            const value = work[start] + band.total_score;
            if (band.score <= peak and value < work[end]) {
                work[end] = value;
                previous[end] = start;
            }
        }
    }
    return previous;
}

const Split = struct { start: usize, end: usize };

fn bandSplits(arena: Allocator, previous: []const ?usize, lines: usize) Allocator.Error![]const Split {
    var splits: std.ArrayList(Split) = .empty;
    var end = lines;
    while (end != 0) {
        const start = previous[end] orelse @panic("Dynamic band reconstruction failed");
        try splits.append(arena, .{ .start = start, .end = end });
        end = start;
    }
    std.mem.reverse(Split, splits.items);
    return splits.items;
}
