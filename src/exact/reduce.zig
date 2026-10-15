//! Removes candidate chords that some optimal solution provably never needs,
//! one certified deletion at a time, since a deletion can enable others
const std = @import("std");
const Allocator = std.mem.Allocator;
const Board = @import("../board.zig").Board;
const model_module = @import("model.zig");
const Model = model_module.Model;
const sorted_set = @import("sorted_set.zig");

const max_bound_search_nodes = 20000;

pub fn reduceCandidates(arena: Allocator, gpa: Allocator, b: *const Board) Allocator.Error!Model {
    const m = try model_module.build(arena, b);
    var relations = try Relations.init(arena, &m);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var worklist: std.heap.ArenaAllocator = .init(gpa);
    defer worklist.deinit();
    try relations.removeByWorklist(worklist.allocator(), b, &scratch);
    return model_module.restrict(arena, &m, relations.alive);
}

const Relations = struct {
    n: u32,
    contacts: []const []const u32,
    contact_bits: []const []const u64,
    bases: []const []const u32,
    mines: []const []const u32,
    alive: []bool,
    alive_bits: []u64,
    mine_users: []u32,

    fn init(arena: Allocator, m: *const Model) Allocator.Error!Relations {
        const b = m.board;
        const n = m.variableCount();
        const z: u32 = @intCast(b.zeros.len);
        const words = (n + 63) / 64;
        const bases = try arena.alloc([]const u32, n);
        const mines = try arena.alloc([]const u32, n);
        for (0..n) |i| {
            bases[i] = try candidateBases(arena, m, @intCast(i), z);
            mines[i] = try candidateMines(arena, b, m.cells[i]);
        }
        const contacts = try candidateContacts(arena, m);
        const contact_bits = try arena.alloc([]const u64, n);
        for (contacts, contact_bits) |list, *out| {
            const bits = try arena.alloc(u64, words);
            @memset(bits, 0);
            for (list) |j| bits[j / 64] |= @as(u64, 1) << @intCast(j % 64);
            out.* = bits;
        }
        const mine_users = try arena.alloc(u32, b.cellCount());
        @memset(mine_users, 0);
        for (mines) |scope| {
            for (scope) |cell| mine_users[cell] += 1;
        }
        const alive = try arena.alloc(bool, n);
        @memset(alive, true);
        const alive_bits = try arena.alloc(u64, words);
        @memset(alive_bits, std.math.maxInt(u64));
        return .{ .n = n, .contacts = contacts, .contact_bits = contact_bits, .bases = bases, .mines = mines, .alive = alive, .alive_bits = alive_bits, .mine_users = mine_users };
    }

    fn remove(r: *Relations, victim: u32) void {
        r.alive[victim] = false;
        r.alive_bits[victim / 64] &= ~(@as(u64, 1) << @intCast(victim % 64));
        for (r.mines[victim]) |cell| r.mine_users[cell] -= 1;
    }

    fn hasSwapReplacement(r: *const Relations, victim: u32) bool {
        for (r.contacts[victim]) |j| {
            if (r.alive[j] and r.canReplace(j, victim)) return true;
        }
        return false;
    }

    fn removeByWorklist(r: *Relations, arena: Allocator, b: *const Board, scratch: *std.heap.ArenaAllocator) Allocator.Error!void {
        const users = try mineUsers(arena, b, r.mines);
        var pending: std.ArrayList(u32) = .empty;
        const queued = try arena.alloc(bool, r.n);
        @memset(queued, true);
        for (0..r.n) |i| try pending.append(arena, @intCast(r.n - 1 - i));
        while (pending.pop()) |v| {
            queued[v] = false;
            if (!r.alive[v]) continue;
            _ = scratch.reset(.retain_capacity);
            if (!r.hasSwapReplacement(v) and !try r.boundAllowsRemoval(scratch.allocator(), v)) continue;
            r.remove(v);
            for (r.contacts[v]) |u| try requeue(arena, &pending, queued, u);
            for (r.mines[v]) |cell| {
                for (users[cell]) |u| try requeue(arena, &pending, queued, u);
            }
        }
    }

    fn canReplace(r: *const Relations, replacement: u32, victim: u32) bool {
        if (!sorted_set.isSubset(r.bases[victim], r.bases[replacement])) return false;
        if (!sorted_set.isSubset(r.mines[replacement], r.mines[victim])) return false;
        for (r.contact_bits[victim], r.contact_bits[replacement], r.alive_bits, 0..) |needed_bits, offered, alive, word| {
            var required = needed_bits & alive;
            if (word == replacement / 64) required &= ~(@as(u64, 1) << @intCast(replacement % 64));
            if (required & ~offered != 0) return false;
        }
        return true;
    }

    fn boundAllowsRemoval(r: *const Relations, arena: Allocator, v: u32) Allocator.Error!bool {
        var adjacent: std.ArrayList(u32) = .empty;
        for (r.contacts[v]) |other| {
            if (r.alive[other]) try adjacent.append(arena, other);
        }
        if (adjacent.items.len > 63 or r.bases[v].len > 63) return false;
        var private_mines: i32 = 0;
        for (r.mines[v]) |cell| private_mines += @intFromBool(r.mine_users[cell] == 1);
        const threshold = 2 + private_mines - @as(i32, @intCast(r.bases[v].len));
        if (threshold < 0) return false;
        if (threshold >= adjacent.items.len) return true;
        var search: LiabilitySearch = try .init(arena, r, v, adjacent.items, threshold);
        const all = (@as(u64, 1) << @intCast(adjacent.items.len)) - 1;
        search.explore(all, 0, 0);
        return !search.exhausted and search.best <= threshold;
    }
};

fn requeue(arena: Allocator, pending: *std.ArrayList(u32), queued: []bool, v: u32) Allocator.Error!void {
    if (queued[v]) return;
    queued[v] = true;
    try pending.append(arena, v);
}

fn mineUsers(arena: Allocator, b: *const Board, mines: []const []const u32) Allocator.Error![]const []const u32 {
    const lists = try arena.alloc(std.ArrayList(u32), b.cellCount());
    @memset(lists, .empty);
    for (mines, 0..) |scope, v| {
        for (scope) |cell| try lists[cell].append(arena, @intCast(v));
    }
    const users = try arena.alloc([]const u32, lists.len);
    for (users, lists) |*out, list| out.* = list.items;
    return users;
}

fn candidateBases(arena: Allocator, m: *const Model, i: u32, z: u32) Allocator.Error![]const u32 {
    const b = m.board;
    const n = m.variableCount();
    const p = m.cells[i];
    var bases: std.ArrayList(u32) = .empty;
    for (b.neighbors[p].slice()) |q| {
        if (!b.mine[q] and b.island[q] == null and b.number[q] > 0 and b.isTarget(q)) try bases.append(arena, z + q);
    }
    if (b.isTarget(p)) try bases.append(arena, z + p);
    for (0..z) |island| {
        if (std.mem.indexOfScalar(u32, m.edges[i], n + @as(u32, @intCast(island))) != null) try bases.append(arena, @intCast(island));
    }
    sorted_set.normalize(&bases);
    return bases.items;
}

fn candidateMines(arena: Allocator, b: *const Board, p: u32) Allocator.Error![]const u32 {
    var mines: std.ArrayList(u32) = .empty;
    for (b.neighbors[p].slice()) |q| {
        if (b.mine[q]) try mines.append(arena, q);
    }
    sorted_set.normalize(&mines);
    return mines.items;
}

fn candidateContacts(arena: Allocator, m: *const Model) Allocator.Error![]const []const u32 {
    const n = m.variableCount();
    const lists = try arena.alloc(std.ArrayList(u32), n);
    @memset(lists, .empty);
    for (m.edges[0..n], lists) |adjacent, *list| {
        for (adjacent) |j| {
            if (j < n) try list.append(arena, j);
        }
    }
    for (m.edges[n..]) |members| {
        for (members) |i| {
            for (members) |j| {
                if (i != j) try lists[i].append(arena, j);
            }
        }
    }
    const contacts = try arena.alloc([]const u32, n);
    for (contacts, lists) |*out, *list| {
        sorted_set.normalize(list);
        out.* = list.items;
    }
    return contacts;
}

const LiabilitySearch = struct {
    links: []const u64,
    hits: []const u64,
    threshold: i32,
    best: i32 = 0,
    visited: u32 = 0,
    exhausted: bool = false,

    fn init(arena: Allocator, r: *const Relations, v: u32, adjacent: []const u32, threshold: i32) Allocator.Error!LiabilitySearch {
        const links = try arena.alloc(u64, adjacent.len);
        const hits = try arena.alloc(u64, adjacent.len);
        for (adjacent, links, hits) |other, *link, *hit| {
            link.* = 0;
            hit.* = 0;
            for (adjacent, 0..) |candidate, j| {
                if ((r.contact_bits[other][candidate / 64] >> @intCast(candidate % 64)) & 1 != 0) link.* |= @as(u64, 1) << @intCast(j);
            }
            for (r.bases[v], 0..) |base, j| {
                if (sorted_set.contains(r.bases[other], base)) hit.* |= @as(u64, 1) << @intCast(j);
            }
        }
        return .{ .links = links, .hits = hits, .threshold = threshold };
    }

    fn explore(s: *LiabilitySearch, available: u64, chosen: i32, covered: u64) void {
        if (s.best > s.threshold or s.exhausted) return;
        s.visited += 1;
        if (s.visited > max_bound_search_nodes) {
            s.exhausted = true;
            return;
        }
        s.best = @max(s.best, chosen - @popCount(covered));
        if (s.best > s.threshold or available == 0) return;
        if (chosen + @popCount(available) - @popCount(covered) <= s.best) return;
        const pivot = s.mostConnected(available);
        const bit = @as(u64, 1) << pivot;
        s.explore(available & ~bit & ~s.links[pivot], chosen + 1, covered | s.hits[pivot]);
        s.explore(available & ~bit, chosen, covered);
    }

    fn mostConnected(s: *const LiabilitySearch, available: u64) u6 {
        var pivot: u6 = @intCast(@ctz(available));
        var pivot_degree: i32 = -1;
        var scan = available;
        while (scan != 0) : (scan &= scan - 1) {
            const at: u6 = @intCast(@ctz(scan));
            const degree: i32 = @popCount(s.links[at] & available);
            if (degree > pivot_degree) {
                pivot = at;
                pivot_degree = degree;
            }
        }
        return pivot;
    }
};
