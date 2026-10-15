//! The exact problem as an optimization model over candidate chords
const std = @import("std");
const Allocator = std.mem.Allocator;
const Board = @import("../board.zig").Board;
const DisjointSets = @import("disjoint_sets.zig").DisjointSets;
const sorted_set = @import("sorted_set.zig");

pub const Factor = struct {
    vars: []const u32,
    mine: bool,
    weight: i32 = 1,
};

pub const Model = struct {
    board: *const Board,
    cells: []const u32,
    edges: []const []const u32,
    factors: []const Factor,
    base: i32,
    removed: i32,
    isolated_zeros: i32,

    pub fn variableCount(m: *const Model) u32 {
        return @intCast(m.cells.len);
    }
};

pub const Selection = struct {
    words: []u64,

    pub fn initEmpty(allocator: Allocator, n: usize) Allocator.Error!Selection {
        const words = try allocator.alloc(u64, (n + 63) / 64);
        @memset(words, 0);
        return .{ .words = words };
    }

    pub fn clone(s: Selection, allocator: Allocator) Allocator.Error!Selection {
        return .{ .words = try allocator.dupe(u64, s.words) };
    }

    pub fn isSet(s: Selection, i: u32) bool {
        return (s.words[i / 64] >> @intCast(i % 64)) & 1 != 0;
    }

    pub fn toggle(s: Selection, i: u32) void {
        s.words[i / 64] ^= @as(u64, 1) << @intCast(i % 64);
    }

    pub fn copyFrom(s: Selection, other: Selection) void {
        @memcpy(s.words, other.words);
    }

    pub fn clear(s: Selection) void {
        @memset(s.words, 0);
    }

    pub fn iterator(s: Selection, n: u32) Iterator {
        return .{ .words = s.words, .n = n };
    }

    pub const Iterator = struct {
        words: []const u64,
        n: u32,
        word: usize = 0,
        bits: u64 = 0,

        pub fn next(it: *Iterator) ?u32 {
            while (it.bits == 0) {
                if (it.word == it.words.len) return null;
                it.bits = it.words[it.word];
                it.word += 1;
            }
            const v: u32 = @intCast((it.word - 1) * 64 + @ctz(it.bits));
            it.bits &= it.bits - 1;
            if (v >= it.n) @panic("Selection has a bit beyond the model's variables");
            return v;
        }
    };
};

pub fn build(arena: Allocator, b: *const Board) Allocator.Error!Model {
    const n_cells = b.cellCount();
    const neighborhoods = try chordNeighborhoods(arena, b);
    var cells: std.ArrayList(u32) = .empty;
    var removed: i32 = 0;
    for (neighborhoods.candidates) |a| {
        if (isDominated(neighborhoods, a)) removed += 1 else try cells.append(arena, a);
    }
    const n: u32 = @intCast(cells.items.len);
    const z: u32 = @intCast(b.zeros.len);
    const id = try arena.alloc(?u32, n_cells);
    @memset(id, null);
    for (cells.items, 0..) |cell, i| id[cell] = @intCast(i);

    const edges = try candidateEdges(arena, b, cells.items, id, z);
    var factors: std.ArrayList(Factor) = .empty;
    var base: i32 = 0;
    try appendMineFactors(arena, b, id, &factors);
    base += try appendTargetFactors(arena, b, id, &factors);
    var isolated: i32 = 0;
    for (edges[n..]) |adjacent| isolated += @intFromBool(adjacent.len == 0);
    base += isolated;
    const folded = try foldFactors(arena, factors.items);
    return .{
        .board = b,
        .cells = cells.items,
        .edges = edges,
        .factors = folded.factors,
        .base = base + folded.constant,
        .removed = removed,
        .isolated_zeros = isolated,
    };
}

const Neighborhoods = struct {
    board: *const Board,
    candidates: []const u32,
    own_safe: []const []const u32,
    islands: []const []const u32,
    mines: []const []const u32,
    useless: []const bool,
    touchers: []const []const u32,
    regions_containing: []const []const u32,
};

fn chordNeighborhoods(arena: Allocator, b: *const Board) Allocator.Error!Neighborhoods {
    const n_cells = b.cellCount();
    const own_safe_cells = try arena.alloc([]const u32, n_cells);
    const touched_islands = try arena.alloc([]const u32, n_cells);
    const mines = try arena.alloc([]const u32, n_cells);
    const useless = try arena.alloc(bool, n_cells);
    @memset(own_safe_cells, &.{});
    @memset(touched_islands, &.{});
    @memset(mines, &.{});
    @memset(useless, false);
    const flood = try floodRegions(arena, b);
    var candidates: std.ArrayList(u32) = .empty;
    const touchers = try arena.alloc(std.ArrayList(u32), b.zeros.len);
    @memset(touchers, .empty);
    for (0..n_cells) |i| {
        if (b.number[i] <= 0) continue;
        const p: u32 = @intCast(i);
        try candidates.append(arena, p);
        const own_safe = try ownSafeCells(arena, b, p);
        const islands = touchedIslands(b, p);
        useless[p] = cannotSaveClicks(own_safe, flood, islands.slice());
        if (useless[p]) continue;
        own_safe_cells[p] = own_safe;
        touched_islands[p] = try arena.dupe(u32, islands.slice());
        mines[p] = try mineNeighbors(arena, b, p);
        for (islands.slice()) |z| try touchers[z].append(arena, p);
    }
    return .{
        .board = b,
        .candidates = candidates.items,
        .own_safe = own_safe_cells,
        .islands = touched_islands,
        .mines = mines,
        .useless = useless,
        .touchers = try listItems(arena, touchers),
        .regions_containing = try regionsContaining(arena, b, flood),
    };
}

fn regionsContaining(arena: Allocator, b: *const Board, flood: []const []const u32) Allocator.Error![]const []const u32 {
    const lists = try arena.alloc(std.ArrayList(u32), b.cellCount());
    @memset(lists, .empty);
    for (flood, 0..) |region, z| {
        for (region) |cell| try lists[cell].append(arena, @intCast(z));
    }
    return listItems(arena, lists);
}

fn listItems(arena: Allocator, lists: []const std.ArrayList(u32)) Allocator.Error![]const []const u32 {
    const items = try arena.alloc([]const u32, lists.len);
    for (items, lists) |*out, list| out.* = list.items;
    return items;
}

fn ownSafeCells(arena: Allocator, b: *const Board, p: u32) Allocator.Error![]const u32 {
    var cells: std.ArrayList(u32) = .empty;
    try cells.append(arena, p);
    for (b.neighbors[p].slice()) |q| {
        if (!b.mine[q]) try cells.append(arena, q);
    }
    sorted_set.normalize(&cells);
    return cells.items;
}

fn mineNeighbors(arena: Allocator, b: *const Board, p: u32) Allocator.Error![]const u32 {
    var cells: std.ArrayList(u32) = .empty;
    for (b.neighbors[p].slice()) |q| {
        if (b.mine[q]) try cells.append(arena, q);
    }
    return cells.items;
}

const TouchedIslands = struct {
    ids: [8]u32 = undefined,
    len: u8 = 0,

    fn slice(t: *const TouchedIslands) []const u32 {
        return t.ids[0..t.len];
    }
};

fn touchedIslands(b: *const Board, p: u32) TouchedIslands {
    var touched: TouchedIslands = .{};
    for (b.neighbors[p].slice()) |q| {
        const z = b.island[q] orelse continue;
        if (std.mem.indexOfScalar(u32, touched.slice(), z) != null) continue;
        touched.ids[touched.len] = z;
        touched.len += 1;
    }
    return touched;
}

fn cannotSaveClicks(own_safe: []const u32, flood: []const []const u32, islands: []const u32) bool {
    if (own_safe.len <= 2) return true;
    for (islands) |z| {
        if (sorted_set.isSubset(own_safe, flood[z])) return true;
    }
    return false;
}

fn floodRegions(arena: Allocator, b: *const Board) Allocator.Error![]const []const u32 {
    const flood = try arena.alloc([]const u32, b.zeros.len);
    for (flood, b.zeros, b.borders) |*out, zeros, borders| {
        var region: std.ArrayList(u32) = .empty;
        try region.appendSlice(arena, zeros);
        try region.appendSlice(arena, borders);
        sorted_set.normalize(&region);
        out.* = region.items;
    }
    return flood;
}

fn isDominated(h: Neighborhoods, a: u32) bool {
    if (h.useless[a]) return true;
    for (h.board.neighbors[a].slice()) |other| {
        if (dominates(h, other, a)) return true;
    }
    for (h.regions_containing[a]) |z| {
        for (h.touchers[z]) |other| {
            if (dominates(h, other, a)) return true;
        }
    }
    return false;
}

fn dominates(h: Neighborhoods, other: u32, a: u32) bool {
    if (a == other or h.board.number[other] <= 0 or h.useless[other]) return false;
    if (!opensSubsetOf(h, a, other) or !sorted_set.isSubset(h.mines[other], h.mines[a])) return false;
    const identical = opensSubsetOf(h, other, a) and std.mem.eql(u32, h.mines[a], h.mines[other]);
    return !identical or other < a;
}

fn opensSubsetOf(h: Neighborhoods, a: u32, other: u32) bool {
    for (h.islands[a]) |z| {
        if (std.mem.indexOfScalar(u32, h.islands[other], z) == null) return false;
    }
    for (h.own_safe[a]) |cell| {
        if (!opensCell(h, other, cell)) return false;
    }
    return true;
}

fn opensCell(h: Neighborhoods, chord: u32, cell: u32) bool {
    if (std.mem.indexOfScalar(u32, h.own_safe[chord], cell) != null) return true;
    for (h.regions_containing[cell]) |z| {
        if (std.mem.indexOfScalar(u32, h.islands[chord], z) != null) return true;
    }
    return false;
}

fn candidateEdges(arena: Allocator, b: *const Board, cells: []const u32, id: []const ?u32, z: u32) Allocator.Error![]const []const u32 {
    const n: u32 = @intCast(cells.len);
    const lists = try arena.alloc(std.ArrayList(u32), n + z);
    @memset(lists, .empty);
    for (cells, 0..) |cell, i| {
        for (b.neighbors[cell].slice()) |q| {
            if (id[q]) |j| try lists[i].append(arena, j);
            if (b.island[q]) |zi| try lists[i].append(arena, n + zi);
        }
        sorted_set.normalize(&lists[i]);
        for (lists[i].items) |j| {
            if (j >= n) try lists[j].append(arena, @intCast(i));
        }
    }
    const edges = try arena.alloc([]const u32, n + z);
    for (edges, lists) |*out, list| out.* = list.items;
    try dropEdgesImpliedByIslands(arena, edges, n);
    return edges;
}

fn dropEdgesImpliedByIslands(arena: Allocator, edges: [][]const u32, n: u32) Allocator.Error!void {
    const original = try arena.dupe([]const u32, edges);
    for (0..n) |i| {
        var kept: std.ArrayList(u32) = .empty;
        for (original[i]) |j| {
            if (j < n and shareIsland(original[i], original[j], n)) continue;
            try kept.append(arena, j);
        }
        edges[i] = kept.items;
    }
}

fn shareIsland(a: []const u32, b: []const u32, n: u32) bool {
    for (a) |v| {
        if (v >= n and sorted_set.contains(b, v)) return true;
    }
    return false;
}

fn appendMineFactors(arena: Allocator, b: *const Board, id: []const ?u32, factors: *std.ArrayList(Factor)) Allocator.Error!void {
    for (0..b.cellCount()) |p| {
        if (!b.mine[p]) continue;
        var vars: std.ArrayList(u32) = .empty;
        for (b.neighbors[p].slice()) |q| {
            if (id[q]) |j| try vars.append(arena, j);
        }
        if (vars.items.len == 0) continue;
        sorted_set.normalize(&vars);
        try factors.append(arena, .{ .vars = vars.items, .mine = true });
    }
}

fn appendTargetFactors(arena: Allocator, b: *const Board, id: []const ?u32, factors: *std.ArrayList(Factor)) Allocator.Error!i32 {
    var uncoverable: i32 = 0;
    for (b.targets) |p| {
        var vars: std.ArrayList(u32) = .empty;
        if (id[p]) |j| try vars.append(arena, j);
        for (b.neighbors[p].slice()) |q| {
            if (id[q]) |j| try vars.append(arena, j);
        }
        sorted_set.normalize(&vars);
        if (vars.items.len == 0) {
            uncoverable += 1;
        } else {
            try factors.append(arena, .{ .vars = vars.items, .mine = false });
        }
    }
    return uncoverable;
}

const Folded = struct { factors: []const Factor, constant: i32 };

fn foldFactors(arena: Allocator, factors: []Factor) Allocator.Error!Folded {
    std.mem.sortUnstable(Factor, factors, {}, scopeLessThan);
    var merged: std.ArrayList(Factor) = .empty;
    var constant: i32 = 0;
    var i: usize = 0;
    while (i < factors.len) {
        var end = i;
        var positive: i32 = 0;
        var negative: i32 = 0;
        while (end < factors.len and std.mem.eql(u32, factors[end].vars, factors[i].vars)) : (end += 1) {
            if (factors[end].mine) positive += factors[end].weight else negative += factors[end].weight;
        }
        constant += @min(positive, negative);
        if (positive != negative) {
            try merged.append(arena, .{
                .vars = factors[i].vars,
                .mine = positive > negative,
                .weight = @intCast(@abs(positive - negative)),
            });
        }
        i = end;
    }
    return .{ .factors = merged.items, .constant = constant };
}

fn scopeLessThan(_: void, a: Factor, b: Factor) bool {
    return std.mem.lessThan(u32, a.vars, b.vars);
}

pub fn restrict(arena: Allocator, parent: *const Model, keep: []const bool) Allocator.Error!Model {
    const map = try keptVariablesAndIslands(arena, parent, keep);
    const n = map.kept.len - (parent.edges.len - parent.cells.len);
    const edges = try remapEdges(arena, parent, map);
    var newly_isolated: i32 = 0;
    for (parent.edges[parent.cells.len..], edges[n..]) |before, after| newly_isolated += @intFromBool(before.len != 0 and after.len == 0);
    const factors = try restrictFactors(arena, parent.factors, map.id);
    const folded = try foldFactors(arena, factors.kept);
    return .{
        .board = parent.board,
        .cells = try cellsOf(arena, parent, map.kept[0..n]),
        .edges = edges,
        .factors = folded.factors,
        .base = parent.base + newly_isolated + factors.uncovered_weight + folded.constant,
        .removed = parent.removed + @as(i32, @intCast(parent.cells.len - n)),
        .isolated_zeros = parent.isolated_zeros + newly_isolated,
    };
}

pub fn piece(arena: Allocator, parent: *const Model, variables: []const u32) Allocator.Error!Model {
    const map = try variablesAndTouchedIslands(arena, parent, variables);
    var factors: std.ArrayList(Factor) = .empty;
    for (parent.factors) |f| {
        if (map.id[f.vars[0]] == null) continue;
        const vars = try arena.alloc(u32, f.vars.len);
        for (f.vars, vars) |v, *out| out.* = map.id[v] orelse @panic("Factor crosses independent pieces");
        try factors.append(arena, .{ .vars = vars, .mine = f.mine, .weight = f.weight });
    }
    return .{
        .board = parent.board,
        .cells = try cellsOf(arena, parent, variables),
        .edges = try remapEdges(arena, parent, map),
        .factors = factors.items,
        .base = 0,
        .removed = 0,
        .isolated_zeros = 0,
    };
}

const VertexMap = struct {
    id: []?u32,
    kept: []const u32,
};

fn keptVariablesAndIslands(arena: Allocator, parent: *const Model, keep: []const bool) Allocator.Error!VertexMap {
    const id = try arena.alloc(?u32, parent.edges.len);
    @memset(id, null);
    var kept: std.ArrayList(u32) = .empty;
    for (0..parent.edges.len) |old| {
        if (old < parent.cells.len and !keep[old]) continue;
        id[old] = @intCast(kept.items.len);
        try kept.append(arena, @intCast(old));
    }
    return .{ .id = id, .kept = kept.items };
}

fn variablesAndTouchedIslands(arena: Allocator, parent: *const Model, variables: []const u32) Allocator.Error!VertexMap {
    const id = try arena.alloc(?u32, parent.edges.len);
    @memset(id, null);
    var kept: std.ArrayList(u32) = .empty;
    try kept.appendSlice(arena, variables);
    for (variables, 0..) |v, i| id[v] = @intCast(i);
    for (parent.edges[parent.cells.len..], parent.cells.len..) |members, island| {
        for (members) |v| {
            if (id[v] == null) continue;
            id[island] = @intCast(kept.items.len);
            try kept.append(arena, @intCast(island));
            break;
        }
    }
    return .{ .id = id, .kept = kept.items };
}

fn remapEdges(arena: Allocator, parent: *const Model, map: VertexMap) Allocator.Error![]const []const u32 {
    const edges = try arena.alloc([]const u32, map.kept.len);
    for (map.kept, edges) |old, *out| {
        var adjacent: std.ArrayList(u32) = .empty;
        for (parent.edges[old]) |q| {
            if (map.id[q]) |mapped| try adjacent.append(arena, mapped);
        }
        out.* = adjacent.items;
    }
    return edges;
}

fn cellsOf(arena: Allocator, parent: *const Model, variables: []const u32) Allocator.Error![]const u32 {
    const cells = try arena.alloc(u32, variables.len);
    for (variables, cells) |v, *cell| cell.* = parent.cells[v];
    return cells;
}

const RestrictedFactors = struct {
    kept: []Factor,
    uncovered_weight: i32,
};

fn restrictFactors(arena: Allocator, factors: []const Factor, id: []const ?u32) Allocator.Error!RestrictedFactors {
    var kept: std.ArrayList(Factor) = .empty;
    var uncovered: i32 = 0;
    for (factors) |f| {
        var vars: std.ArrayList(u32) = .empty;
        for (f.vars) |v| {
            if (id[v]) |mapped| try vars.append(arena, mapped);
        }
        if (vars.items.len != 0) {
            try kept.append(arena, .{ .vars = vars.items, .mine = f.mine, .weight = f.weight });
        } else if (!f.mine) {
            uncovered += f.weight;
        }
    }
    return .{ .kept = kept.items, .uncovered_weight = uncovered };
}

pub fn factorsByVariable(arena: Allocator, m: *const Model) Allocator.Error![]const []const u32 {
    const lists = try arena.alloc(std.ArrayList(u32), m.cells.len);
    @memset(lists, .empty);
    for (m.factors, 0..) |factor, f| {
        for (factor.vars) |v| try lists[v].append(arena, @intCast(f));
    }
    return listItems(arena, lists);
}

pub const Breakdown = struct {
    flags: i32 = 0,
    chords: i32 = 0,
    chains: i32 = 0,
    remaining: i32 = 0,

    pub fn total(b: Breakdown) i32 {
        return b.flags + b.chords + b.chains + b.remaining;
    }
};

pub fn breakdown(arena: Allocator, m: *const Model, chosen: Selection) Allocator.Error!Breakdown {
    const b = m.board;
    var sets = try DisjointSets.init(arena, m.edges.len);
    const graph = components(&sets, m, chosen);
    const flagged = try arena.alloc(bool, b.cellCount());
    const covered = try arena.alloc(bool, b.cellCount());
    @memset(flagged, false);
    @memset(covered, false);
    for (m.cells, 0..) |cell, i| {
        if (!chosen.isSet(@intCast(i))) continue;
        covered[cell] = true;
        for (b.neighbors[cell].slice()) |q| {
            if (b.mine[q]) flagged[q] = true else covered[q] = true;
        }
    }
    var result: Breakdown = .{ .chords = graph.chords, .chains = graph.chains };
    result.flags = @intCast(std.mem.count(bool, flagged, &.{true}));
    for (b.targets) |p| result.remaining += @intFromBool(!covered[p]);
    return result;
}

pub const Objective = struct {
    model: *const Model,
    sets: DisjointSets,
    scope_words: []const []const ScopeWord,

    const ScopeWord = struct { word: u32, mask: u64 };

    pub fn init(allocator: Allocator, model: *const Model) Allocator.Error!Objective {
        return .{
            .model = model,
            .sets = try DisjointSets.init(allocator, model.edges.len),
            .scope_words = try scopeWords(allocator, model.factors),
        };
    }

    pub fn cost(o: *Objective, chosen: Selection) i32 {
        const m = o.model;
        const graph = components(&o.sets, m, chosen);
        var total = m.base - m.isolated_zeros + graph.chords + graph.chains;
        for (m.factors, o.scope_words) |factor, scope| {
            if (anyWordSelected(scope, chosen) == factor.mine) total += factor.weight;
        }
        return total;
    }

    fn scopeWords(allocator: Allocator, factors: []const Factor) Allocator.Error![]const []const ScopeWord {
        const result = try allocator.alloc([]const ScopeWord, factors.len);
        for (factors, result) |factor, *out| {
            var words: std.ArrayList(ScopeWord) = .empty;
            for (factor.vars) |v| {
                const bit = @as(u64, 1) << @intCast(v % 64);
                if (words.items.len != 0 and words.items[words.items.len - 1].word == v / 64) {
                    words.items[words.items.len - 1].mask |= bit;
                } else {
                    try words.append(allocator, .{ .word = v / 64, .mask = bit });
                }
            }
            out.* = words.items;
        }
        return result;
    }

    fn anyWordSelected(scope: []const ScopeWord, chosen: Selection) bool {
        for (scope) |entry| {
            if (chosen.words[entry.word] & entry.mask != 0) return true;
        }
        return false;
    }
};

const Components = struct { chords: i32, chains: i32 };

fn components(sets: *DisjointSets, m: *const Model, chosen: Selection) Components {
    const n = m.variableCount();
    sets.reset();
    var result: Components = .{ .chords = 0, .chains = 0 };
    var selected = chosen.iterator(n);
    while (selected.next()) |v| {
        result.chords += 1;
        for (m.edges[v]) |u| {
            if (isActive(u, n, chosen)) sets.join(v, u);
        }
    }
    for (n..m.edges.len) |z| result.chains += @intFromBool(sets.root(@intCast(z)) == z);
    selected = chosen.iterator(n);
    while (selected.next()) |v| result.chains += @intFromBool(sets.root(v) == v);
    return result;
}

fn isActive(v: u32, n: u32, chosen: Selection) bool {
    return v >= n or chosen.isSet(v);
}
