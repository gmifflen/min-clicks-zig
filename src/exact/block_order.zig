//! Exact re-planning of short stretches of an order
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const order_module = @import("order.zig");
const conn_weight = order_module.conn_weight;
const factor_weight = order_module.factor_weight;

const max_block = 18;
const weight_scale = 100;
const width_exp_scale = 8.0;

pub fn optimizeStrips(gpa: Allocator, m: *const Model, order: []u32, rows: bool, band: u32) Allocator.Error!void {
    const b = m.board;
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    var begin: usize = 0;
    while (begin < order.len) {
        const strip = stripOf(m, order[begin], rows, band, b.width);
        var end = begin + 1;
        while (end < order.len and stripOf(m, order[end], rows, band, b.width) == strip) end += 1;
        try ends.append(gpa, end);
        begin = end;
    }
    try optimizeBlocks(gpa, m, order, ends.items);
}

fn stripOf(m: *const Model, v: u32, rows: bool, band: u32, width: u32) u32 {
    const cell = m.cells[v];
    return (if (rows) cell / width else cell % width) / band;
}

pub fn optimizeWindows(gpa: Allocator, m: *const Model, order: []u32, size: usize, offset: usize) Allocator.Error!void {
    if (size < 1 or size > max_block or offset >= size) @panic("Invalid order-refinement window");
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    var begin: usize = 0;
    var end = size - offset;
    while (begin < order.len) : ({
        begin = end;
        end += size;
    }) try ends.append(gpa, @min(order.len, end));
    try optimizeBlocks(gpa, m, order, ends.items);
}

fn optimizeBlocks(gpa: Allocator, m: *const Model, order: []u32, ends: []const usize) Allocator.Error!void {
    var begin: usize = 0;
    var largest: usize = 0;
    for (ends) |end| {
        if (end - begin > max_block) return;
        largest = @max(largest, end - begin);
        begin = end;
    }
    var tables = try SubsetTables.init(gpa, @as(usize, 1) << @intCast(largest));
    defer tables.deinit(gpa);
    const pos = try order_module.positions(gpa, order);
    defer gpa.free(pos);
    const widths = try gpa.alloc([]const i32, ends.len);
    var computed: usize = 0;
    defer {
        for (widths[0..computed]) |w| gpa.free(w);
        gpa.free(widths);
    }
    var global_peak: i32 = 0;
    begin = 0;
    for (ends, widths) |end, *out| {
        out.* = try blockWidths(gpa, tables, m, pos, begin, end);
        computed += 1;
        global_peak = @max(global_peak, lowestPeak(tables.peak, out.*));
        begin = end;
    }
    const growth = try workGrowthTable(gpa, global_peak);
    defer gpa.free(growth);
    const optimized = try gpa.alloc(u32, order.len);
    defer gpa.free(optimized);
    begin = 0;
    for (ends, widths) |end, block_widths| {
        cheapestPermutation(tables, growth, optimized[begin..end], order[begin..end], block_widths, global_peak);
        begin = end;
    }
    @memcpy(order, optimized);
}

fn workGrowthTable(gpa: Allocator, peak: i32) Allocator.Error![]f64 {
    const table = try gpa.alloc(f64, @intCast(@divFloor(peak, weight_scale) + 1));
    for (table, 0..) |*value, k| {
        const width: i32 = @intCast(k * weight_scale);
        value.* = @exp2(@as(f64, @floatFromInt(width)) / (width_exp_scale * weight_scale));
    }
    return table;
}

fn workGrowth(table: []const f64, width: i32) f64 {
    if (width < 0 or @rem(width, weight_scale) != 0) @panic("Block width is not a non-negative multiple of the weight scale");
    return table[@intCast(@divTrunc(width, weight_scale))];
}

const SubsetTables = struct {
    direct: []i32,
    complement: []i32,
    peak: []i32,
    cost: []f64,
    parent: []u8,

    fn init(gpa: Allocator, size: usize) Allocator.Error!SubsetTables {
        var tables: SubsetTables = undefined;
        tables.direct = try gpa.alloc(i32, size);
        errdefer gpa.free(tables.direct);
        tables.complement = try gpa.alloc(i32, size);
        errdefer gpa.free(tables.complement);
        tables.peak = try gpa.alloc(i32, size);
        errdefer gpa.free(tables.peak);
        tables.cost = try gpa.alloc(f64, size);
        errdefer gpa.free(tables.cost);
        tables.parent = try gpa.alloc(u8, size);
        return tables;
    }

    fn deinit(tables: SubsetTables, gpa: Allocator) void {
        gpa.free(tables.direct);
        gpa.free(tables.complement);
        gpa.free(tables.peak);
        gpa.free(tables.cost);
        gpa.free(tables.parent);
    }
};

const Placement = struct { mask: u32 = 0, before: bool = false, after: bool = false };

fn place(scope: []const u32, pos: []const u32, n: u32, begin: usize, end: usize) Placement {
    var result: Placement = .{};
    for (scope) |v| {
        if (v >= n) continue;
        const p = pos[v];
        if (p < begin) {
            result.before = true;
        } else if (p >= end) {
            result.after = true;
        } else {
            result.mask |= @as(u32, 1) << @intCast(p - begin);
        }
    }
    return result;
}

fn blockWidths(gpa: Allocator, tables: SubsetTables, m: *const Model, pos: []const u32, begin: usize, end: usize) Allocator.Error![]const i32 {
    const n = m.variableCount();
    const size = @as(usize, 1) << @intCast(end - begin);
    var terms: WidthTerms = .{
        .direct = tables.direct[0..size],
        .complement = tables.complement[0..size],
    };
    @memset(terms.direct, 0);
    @memset(terms.complement, 0);
    for (0..n) |v| {
        if (pos[v] >= end) continue;
        terms.addVariable(place(m.edges[v], pos, n, begin, end), pos[v], begin);
    }
    for (m.edges[n..]) |scope| terms.addHyperedge(place(scope, pos, n, begin, end), conn_weight);
    for (m.factors) |factor| terms.addHyperedge(place(factor.vars, pos, n, begin, end), factor_weight);
    return terms.widths(gpa);
}

const WidthTerms = struct {
    direct: []i32,
    complement: []i32,
    constant: i32 = 0,

    fn addVariable(t: *WidthTerms, neighbors: Placement, position: usize, begin: usize) void {
        if (position < begin) {
            t.constant += conn_weight;
            if (!neighbors.after) t.direct[neighbors.mask] -= conn_weight;
            return;
        }
        const self = @as(u32, 1) << @intCast(position - begin);
        t.direct[self] += conn_weight;
        if (!neighbors.after) t.direct[neighbors.mask | self] -= conn_weight;
    }

    fn addHyperedge(t: *WidthTerms, scope: Placement, weight: i32) void {
        if (scope.mask == 0 and !scope.before and !scope.after) return;
        t.constant += weight;
        if (!scope.before) t.complement[scope.mask] -= weight;
        if (!scope.after) t.direct[scope.mask] -= weight;
    }

    fn widths(t: *WidthTerms, gpa: Allocator) Allocator.Error![]const i32 {
        const size = t.direct.len;
        sumOverSubsets(t.direct);
        sumOverSubsets(t.complement);
        const result = try gpa.alloc(i32, size);
        for (result, 0..) |*w, mask| w.* = t.constant + t.direct[mask] + t.complement[(size - 1) ^ mask];
        return result;
    }
};

fn sumOverSubsets(values: []i32) void {
    var half: usize = 1;
    while (half < values.len) : (half <<= 1) {
        var block: usize = 0;
        while (block < values.len) : (block += 2 * half) {
            for (values[block + half ..][0..half], values[block..][0..half]) |*upper, lower| upper.* += lower;
        }
    }
}

fn lowestPeak(peak: []i32, widths: []const i32) i32 {
    peak[0] = widths[0];
    for (1..widths.len) |mask| {
        var best_before: i32 = std.math.maxInt(i32);
        var bits: usize = mask;
        while (bits != 0) : (bits &= bits - 1) best_before = @min(best_before, peak[mask ^ (bits & (~bits +% 1))]);
        peak[mask] = @max(best_before, widths[mask]);
    }
    return peak[widths.len - 1];
}

fn cheapestPermutation(tables: SubsetTables, growth: []const f64, out: []u32, block: []const u32, widths: []const i32, peak: i32) void {
    const size = widths.len;
    const cost = tables.cost[0..size];
    const parent = tables.parent[0..size];
    @memset(cost, std.math.inf(f64));
    const no_parent = std.math.maxInt(u8);
    @memset(parent, no_parent);
    cost[0] = 0;
    for (1..size) |mask| {
        if (widths[mask] > peak) continue;
        const increment = workGrowth(growth, widths[mask]);
        var bits: usize = mask;
        while (bits != 0) : (bits &= bits - 1) {
            const bit = bits & (~bits +% 1);
            const value = cost[mask ^ bit] + increment;
            if (value <= cost[mask]) {
                cost[mask] = value;
                parent[mask] = @ctz(bit);
            }
        }
    }
    var mask = size - 1;
    var slot = block.len;
    while (mask != 0) {
        const last = parent[mask];
        if (last == no_parent) @panic("Strip planner failed to reconstruct an order");
        slot -= 1;
        out[slot] = block[last];
        mask ^= @as(usize, 1) << @intCast(last);
    }
}
