//! Splits a model into pieces that can be solved independently
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_module = @import("model.zig");
const Model = model_module.Model;
const DisjointSets = @import("disjoint_sets.zig").DisjointSets;
const sorted_set = @import("sorted_set.zig");

pub fn independentParts(arena: Allocator, m: *const Model) Allocator.Error![]const []const u32 {
    const n = m.variableCount();
    var finder: BlockFinder = .{
        .arena = arena,
        .graph = try interactionGraph(arena, m),
        .n = n,
        .discovered = try arena.alloc(i32, m.edges.len),
        .low = try arena.alloc(i32, m.edges.len),
        .same_piece = try DisjointSets.init(arena, n),
    };
    @memset(finder.discovered, -1);
    for (0..m.edges.len) |v| {
        if (finder.discovered[v] < 0) try finder.visit(@intCast(v), null);
    }
    return groupByRoot(arena, finder.same_piece, n);
}

fn interactionGraph(arena: Allocator, m: *const Model) Allocator.Error![]const []const u32 {
    const lists = try arena.alloc(std.ArrayList(u32), m.edges.len);
    for (lists, m.edges) |*list, adjacent| {
        list.* = .empty;
        try list.appendSlice(arena, adjacent);
    }
    for (m.factors) |factor| {
        const a = factor.vars[0];
        for (factor.vars[1..]) |b| {
            try lists[a].append(arena, b);
            try lists[b].append(arena, a);
        }
    }
    const graph = try arena.alloc([]const u32, lists.len);
    for (graph, lists) |*out, *list| {
        sorted_set.normalize(list);
        out.* = list.items;
    }
    return graph;
}

/// Tarjan's biconnected-block search
const BlockFinder = struct {
    arena: Allocator,
    graph: []const []const u32,
    n: u32,
    discovered: []i32,
    low: []i32,
    edge_stack: std.ArrayList([2]u32) = .empty,
    same_piece: DisjointSets,
    time: i32 = 0,

    fn visit(f: *BlockFinder, v: u32, parent: ?u32) Allocator.Error!void {
        f.discovered[v] = f.time;
        f.low[v] = f.time;
        f.time += 1;
        for (f.graph[v]) |u| {
            if (parent) |p| {
                if (u == p) continue;
            }
            if (f.discovered[u] < 0) {
                try f.edge_stack.append(f.arena, .{ v, u });
                try f.visit(u, v);
                f.low[v] = @min(f.low[v], f.low[u]);
                if (f.low[u] >= f.discovered[v]) f.closeBlock(.{ v, u });
            } else if (f.discovered[u] < f.discovered[v]) {
                try f.edge_stack.append(f.arena, .{ v, u });
                f.low[v] = @min(f.low[v], f.discovered[u]);
            }
        }
    }

    fn closeBlock(f: *BlockFinder, tree_edge: [2]u32) void {
        var anchor: ?u32 = null;
        while (true) {
            const edge = f.edge_stack.pop() orelse @panic("A block's tree edge is missing from the edge stack");
            for (edge) |endpoint| {
                if (endpoint >= f.n) continue;
                if (anchor) |a| f.same_piece.join(a, endpoint) else anchor = endpoint;
            }
            if (edge[0] == tree_edge[0] and edge[1] == tree_edge[1]) return;
        }
    }
};

fn groupByRoot(arena: Allocator, sets: DisjointSets, n: u32) Allocator.Error![]const []const u32 {
    var parts: std.ArrayList(std.ArrayList(u32)) = .empty;
    const part_for = try arena.alloc(?u32, n);
    @memset(part_for, null);
    for (0..n) |i| {
        const v: u32 = @intCast(i);
        const root = sets.root(v);
        const part = part_for[root] orelse new: {
            const added: u32 = @intCast(parts.items.len);
            part_for[root] = added;
            try parts.append(arena, .empty);
            break :new added;
        };
        try parts.items[part].append(arena, v);
    }
    const result = try arena.alloc([]const u32, parts.items.len);
    for (result, parts.items) |*out, list| out.* = list.items;
    return result;
}
