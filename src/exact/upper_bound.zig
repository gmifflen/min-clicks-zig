//! A feasible starting solution for the DP to prune against
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Objective = model_module.Objective;
const Selection = model_module.Selection;
const Mt19937 = @import("../mersenne_twister.zig").Mt19937;
const sorted_set = @import("sorted_set.zig");

pub const Incumbent = struct {
    best: i32,
    chosen: Selection,
};

/// Descents start from the empty selection,
/// from random dense selections and from the candidates among `eight_way_chords` (board cells)
/// a two-chord descent finishes from the best solution found.
pub fn initialIncumbent(arena: Allocator, objective: *Objective, eight_way_chords: []const u32) Allocator.Error!Incumbent {
    const n = objective.model.cells.len;
    var search = try FlipEvaluator.init(arena, objective);
    search.restart();
    steepestDescent(&search);
    var best: Incumbent = .{ .best = search.cost, .chosen = try search.chosen.clone(arena) };
    // A chord that does not pay alone can pay with shared flags and a shared seed
    // Descending from dense selections escapes that local minimum
    var rng = Mt19937.init(0x5eed);
    const order = try arena.alloc(u32, n);
    for (order, 0..) |*v, i| v.* = @intCast(i);
    for (0..4) |density| {
        seedSelection(search.chosen, n, &rng, @intCast(density));
        search.restart();
        randomizedDescent(&search, &rng, order);
        keepIfBetter(&best, &search);
    }
    search.chosen.copyFrom(try candidatesAmong(arena, objective.model, eight_way_chords));
    search.restart();
    steepestDescent(&search);
    keepIfBetter(&best, &search);
    search.chosen.copyFrom(best.chosen);
    search.restart();
    pairDescent(&search, try relatedChords(arena, objective.model, search.factors_of));
    keepIfBetter(&best, &search);
    return best;
}

fn keepIfBetter(best: *Incumbent, search: *const FlipEvaluator) void {
    if (search.cost >= best.best) return;
    best.best = search.cost;
    best.chosen.copyFrom(search.chosen);
}

/// The candidates of `m` whose cells are among `cells`, as a selection
fn candidatesAmong(arena: Allocator, m: *const Model, cells: []const u32) Allocator.Error!Selection {
    const candidate_at = try arena.alloc(?u32, m.board.cellCount());
    @memset(candidate_at, null);
    for (m.cells, 0..) |cell, i| candidate_at[cell] = @intCast(i);
    const selection = try Selection.initEmpty(arena, m.cells.len);
    for (cells) |cell| {
        const v = candidate_at[cell] orelse continue;
        if (!selection.isSet(v)) selection.toggle(v);
    }
    return selection;
}

/// Chords whose flips interact:
/// neighbors in the graph and chords sharing a factor
/// Only later chords are listed, so each pair appears once
fn relatedChords(arena: Allocator, m: *const Model, factors_of: []const []const u32) Allocator.Error![]const []const u32 {
    const n = m.variableCount();
    const related = try arena.alloc([]const u32, n);
    for (related, 0..) |*out, v| {
        var list: std.ArrayList(u32) = .empty;
        for (m.edges[v]) |u| {
            if (u < n and u > v) try list.append(arena, u);
        }
        for (factors_of[v]) |f| {
            for (m.factors[f].vars) |u| {
                if (u > v) try list.append(arena, u);
            }
        }
        sorted_set.normalize(&list);
        out.* = list.items;
    }
    return related;
}

/// A pair can only pay where sharing flags,
/// seeds or targets saves what its single flips lose,
/// so only chords within this many clicks of paying alone are tried
/// each trial rebuilds the connectivity forest twice
const pair_trial_margin = 2;

/// Flips related pairs together while that helps, then single chords again
/// Single flips miss pairs that only pay by sharing a flag or a seed
fn pairDescent(search: *FlipEvaluator, related: []const []const u32) void {
    var pass: u32 = 0;
    var improved = true;
    while (pass < 4 and improved) : (pass += 1) {
        improved = false;
        for (related, 0..) |partners, v| {
            if (search.costAfterFlip(@intCast(v)) > search.cost + pair_trial_margin) continue;
            if (!applyImprovingPair(search, @intCast(v), partners)) continue;
            improved = true;
            steepestDescent(search);
        }
    }
}

/// Applies the first improving pair (v, partner),
/// if any, otherwise leaves the selection as it was
fn applyImprovingPair(search: *FlipEvaluator, v: u32, partners: []const u32) bool {
    if (partners.len == 0) return false;
    const before = search.cost;
    search.flip(v, search.costAfterFlip(v));
    for (partners) |u| {
        const cost = search.costAfterFlip(u);
        if (cost >= before) continue;
        search.flip(u, cost);
        return true;
    }
    search.flip(v, search.costAfterFlip(v));
    return false;
}

/// Repeatedly applies the single best improving flip
fn steepestDescent(search: *FlipEvaluator) void {
    while (true) {
        var best = search.cost;
        var best_flip: ?u32 = null;
        for (0..search.objective.model.cells.len) |i| {
            const cost = search.costAfterFlip(@intCast(i));
            if (cost < best) {
                best = cost;
                best_flip = @intCast(i);
            }
        }
        search.flip(best_flip orelse return, best);
    }
}

/// Density 0 selects everything
/// density d selects each chord with probability d/4
/// Draws exactly as many random numbers as the reference
fn seedSelection(chosen: Selection, n: usize, rng: *Mt19937, density: u32) void {
    chosen.clear();
    for (0..n) |i| {
        if (density == 0 or rng.next() % 4 < density) chosen.toggle(@intCast(i));
    }
}

/// Up to 12 shuffled first-improvement passes
/// Equal-cost flips that drop a chord are accepted
/// steering towards sparser selections
fn randomizedDescent(search: *FlipEvaluator, rng: *Mt19937, order: []u32) void {
    var pass: u32 = 0;
    var improved = true;
    while (pass < 12 and improved) : (pass += 1) {
        improved = false;
        shuffle(order, rng);
        for (order) |v| {
            const value = search.costAfterFlip(v);
            if (value > search.cost or (value == search.cost and !search.chosen.isSet(v))) continue;
            improved = improved or value < search.cost;
            search.flip(v, value);
        }
    }
}

/// Biased-modulo Fisher-Yates
fn shuffle(order: []u32, rng: *Mt19937) void {
    var j = order.len;
    while (j > 1) {
        j -= 1;
        std.mem.swap(u32, &order[j], &order[rng.next() % @as(u32, @intCast(j + 1))]);
    }
}

/// Prices a single-chord flip exactly
/// in time proportional to the chord's neighborhood rather than the whole model
/// Only factors containing the chord can change
/// and the component count follows from the DFS forest of the current selectionL:
/// a new chord merges its neighbors' components,
/// and a removed chord splits its component into one piece per articulation child (plus its parent's side)
/// The forest is rebuilt only when a flip is kept
const FlipEvaluator = struct {
    objective: *Objective,
    chosen: Selection,
    cost: i32 = 0,
    factors_of: []const []const u32,
    /// Selected variables in each factor's scope
    selected_in: []u32,
    forest: ActiveForest,

    fn init(arena: Allocator, objective: *Objective) Allocator.Error!FlipEvaluator {
        const m = objective.model;
        return .{
            .objective = objective,
            .chosen = try Selection.initEmpty(arena, m.cells.len),
            .factors_of = try model_module.factorsByVariable(arena, m),
            .selected_in = try arena.alloc(u32, m.factors.len),
            .forest = try ActiveForest.init(arena, m),
        };
    }

    /// Resynchronizes after `chosen` was changed wholesale
    fn restart(e: *FlipEvaluator) void {
        e.cost = e.objective.cost(e.chosen);
        for (e.objective.model.factors, e.selected_in) |factor, *count| {
            count.* = 0;
            for (factor.vars) |v| count.* += @intFromBool(e.chosen.isSet(v));
        }
        e.forest.rebuild(e.chosen);
    }

    fn costAfterFlip(e: *const FlipEvaluator, v: u32) i32 {
        const adding = !e.chosen.isSet(v);
        const chains_after = if (adding)
            e.forest.roots + 1 - e.forest.distinctNeighborComponents(v, e.chosen)
        else
            e.forest.roots - 1 + e.forest.piecesWithout(v);
        var cost = e.cost + (if (adding) @as(i32, 1) else -1) + @as(i32, @intCast(chains_after)) - @as(i32, @intCast(e.forest.roots));
        for (e.factors_of[v]) |f| {
            const factor = e.objective.model.factors[f];
            const count = e.selected_in[f];
            const toggles = if (adding) count == 0 else count == 1;
            if (!toggles) continue;
            // A mine factor charges while used, a target factor while unused.
            cost += if (adding == factor.mine) factor.weight else -factor.weight;
        }
        return cost;
    }

    fn flip(e: *FlipEvaluator, v: u32, new_cost: i32) void {
        const adding = !e.chosen.isSet(v);
        e.chosen.toggle(v);
        for (e.factors_of[v]) |f| {
            if (adding) e.selected_in[f] += 1 else e.selected_in[f] -= 1;
        }
        e.forest.rebuild(e.chosen);
        e.cost = new_cost;
    }
};

/// A DFS forest over the active vertices (zero islands plus selected chords)
/// with the articulation data needed to price removals
const ActiveForest = struct {
    edges: []const []const u32,
    n: u32,
    roots: u32 = 0,
    component: []u32,
    /// DFS discovery time
    discovered: []u32,
    low: []u32,
    parent: []?u32,
    /// Children whose subtree would be cut off by removing the vertex
    separated: []u32,
    stack: []Frame,

    const Frame = struct { v: u32, next_edge: u32 };

    fn init(arena: Allocator, m: *const Model) Allocator.Error!ActiveForest {
        const total = m.edges.len;
        return .{
            .edges = m.edges,
            .n = m.variableCount(),
            .component = try arena.alloc(u32, total),
            .discovered = try arena.alloc(u32, total),
            .low = try arena.alloc(u32, total),
            .parent = try arena.alloc(?u32, total),
            .separated = try arena.alloc(u32, total),
            .stack = try arena.alloc(Frame, total),
        };
    }

    fn isActive(f: *const ActiveForest, v: u32, chosen: Selection) bool {
        return v >= f.n or chosen.isSet(v);
    }

    fn rebuild(f: *ActiveForest, chosen: Selection) void {
        @memset(f.discovered, 0);
        f.roots = 0;
        var time: u32 = 0;
        for (0..f.edges.len) |i| {
            const root: u32 = @intCast(i);
            if (f.discovered[root] != 0 or !f.isActive(root, chosen)) continue;
            f.roots += 1;
            f.explore(root, chosen, &time);
        }
    }

    /// Iterative Tarjan DFS from `root`
    fn explore(f: *ActiveForest, root: u32, chosen: Selection, time: *u32) void {
        f.visit(root, null, time);
        f.stack[0] = .{ .v = root, .next_edge = 0 };
        var depth: usize = 1;
        while (depth > 0) {
            const top = &f.stack[depth - 1];
            const v = top.v;
            if (top.next_edge < f.edges[v].len) {
                const u = f.edges[v][top.next_edge];
                top.next_edge += 1;
                if (!f.isActive(u, chosen)) continue;
                if (f.discovered[u] == 0) {
                    f.visit(u, v, time);
                    f.stack[depth] = .{ .v = u, .next_edge = 0 };
                    depth += 1;
                } else if (!isParent(f.parent[v], u)) {
                    f.low[v] = @min(f.low[v], f.discovered[u]);
                }
                continue;
            }
            depth -= 1;
            const p = f.parent[v] orelse continue;
            f.low[p] = @min(f.low[p], f.low[v]);
            if (f.low[v] >= f.discovered[p]) f.separated[p] += 1;
        }
    }

    fn isParent(parent: ?u32, u: u32) bool {
        return if (parent) |p| p == u else false;
    }

    fn visit(f: *ActiveForest, v: u32, parent: ?u32, time: *u32) void {
        time.* += 1;
        f.discovered[v] = time.*;
        f.low[v] = time.*;
        f.parent[v] = parent;
        f.separated[v] = 0;
        f.component[v] = f.roots;
    }

    /// Components a removed vertex leaves behind
    /// one per separated child, plus the side containing its parent
    fn piecesWithout(f: *const ActiveForest, v: u32) u32 {
        return f.separated[v] + @intFromBool(f.parent[v] != null);
    }

    /// Components an added chord would merge
    /// A chord has at most eight neighbors on the board,
    /// so at most eight distinct components
    fn distinctNeighborComponents(f: *const ActiveForest, v: u32, chosen: Selection) u32 {
        var seen: [8]u32 = undefined;
        var count: u32 = 0;
        for (f.edges[v]) |u| {
            if (!f.isActive(u, chosen)) continue;
            const c = f.component[u];
            if (std.mem.indexOfScalar(u32, seen[0..count], c) != null) continue;
            if (count == seen.len) @panic("A chord touches more than eight components");
            seen[count] = c;
            count += 1;
        }
        return count;
    }
};
