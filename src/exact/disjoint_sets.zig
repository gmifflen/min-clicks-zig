const std = @import("std");
const Allocator = std.mem.Allocator;

/// Union-find with path halving
/// `join(a, b)` hangs a's root under b's root
pub const DisjointSets = struct {
    parent: []u32,

    pub fn init(allocator: Allocator, n: usize) Allocator.Error!DisjointSets {
        const sets: DisjointSets = .{ .parent = try allocator.alloc(u32, n) };
        sets.reset();
        return sets;
    }

    pub fn reset(sets: DisjointSets) void {
        for (sets.parent, 0..) |*p, i| p.* = @intCast(i);
    }

    pub fn root(sets: DisjointSets, start: u32) u32 {
        var a = start;
        while (sets.parent[a] != a) {
            sets.parent[a] = sets.parent[sets.parent[a]];
            a = sets.parent[a];
        }
        return a;
    }

    pub fn join(sets: DisjointSets, a: u32, b: u32) void {
        sets.parent[sets.root(a)] = sets.root(b);
    }
};
