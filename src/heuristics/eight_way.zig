const std = @import("std");
const Allocator = std.mem.Allocator;
const Board = @import("../board.zig").Board;
const action = @import("../action.zig");
const ActionLog = action.ActionLog;
const HeuristicResult = action.HeuristicResult;

/// Premiums never exceed 8, so buckets 0..8 hold every chordable cell
const bucket_count = 9;

/// The premium of a cell that is not a number
const never_chord = -100;

/// Cells with non-negative premium, bucketed by premium
/// Bits within a bucket are traversal ranks,
/// so the lowest set bit is the direction's tie-break
const PremiumQueue = struct {
    words: usize,
    bits: []u64,
    rank: []u32,
    cell: []u32,
    premium: []i32,
    counts: [bucket_count]u32 = @splat(0),
    active: u32 = 0,

    fn init(arena: Allocator, n: usize) Allocator.Error!PremiumQueue {
        const words = (n + 63) / 64;
        return .{
            .words = words,
            .bits = try arena.alloc(u64, bucket_count * words),
            .rank = try arena.alloc(u32, n),
            .cell = try arena.alloc(u32, n),
            .premium = try arena.alloc(i32, n),
        };
    }

    /// Direction bit 0 mirrors x, bit 1 mirrors y, bit 2 ranks column-major
    fn reset(q: *PremiumQueue, b: *const Board, initial: []const i32, direction: u3) void {
        @memcpy(q.premium, initial);
        @memset(q.bits, 0);
        q.counts = @splat(0);
        q.active = 0;
        for (0..b.height) |yy| {
            for (0..b.width) |xx| {
                const rx = if (direction & 1 != 0) b.width - 1 - xx else xx;
                const ry = if (direction & 2 != 0) b.height - 1 - yy else yy;
                const r: u32 = @intCast(if (direction & 4 != 0) ry + b.height * rx else rx + b.width * ry);
                const p = yy * b.width + xx;
                q.rank[p] = r;
                q.cell[r] = @intCast(p);
                if (q.premium[p] >= 0) q.insert(@intCast(q.premium[p]), r);
            }
        }
    }

    fn change(q: *PremiumQueue, p: u32, delta: i32) void {
        const r = q.rank[p];
        const old = q.premium[p];
        const value = old + delta;
        if (value >= bucket_count) @panic("8-way premium exceeds 8");
        if (old >= 0) q.remove(@intCast(old), r);
        q.premium[p] = value;
        if (value >= 0) q.insert(@intCast(value), r);
    }

    fn insert(q: *PremiumQueue, bucket: u32, r: u32) void {
        q.bits[bucket * q.words + r / 64] |= @as(u64, 1) << @intCast(r % 64);
        q.counts[bucket] += 1;
        q.active |= @as(u32, 1) << @intCast(bucket);
    }

    fn remove(q: *PremiumQueue, bucket: u32, r: u32) void {
        q.bits[bucket * q.words + r / 64] &= ~(@as(u64, 1) << @intCast(r % 64));
        q.counts[bucket] -= 1;
        if (q.counts[bucket] == 0) q.active &= ~(@as(u32, 1) << @intCast(bucket));
    }

    fn best(q: *const PremiumQueue) ?u32 {
        if (q.active == 0) return null;
        const bucket: usize = 31 - @clz(q.active);
        for (0..q.words) |word| {
            const mask = q.bits[bucket * q.words + word];
            if (mask != 0) return q.cell[64 * word + @ctz(mask)];
        }
        @panic("8-way premium bucket marked active but empty");
    }
};

pub fn eightWayZini(arena: Allocator, b: *const Board, recording: action.Recording) Allocator.Error!HeuristicResult {
    const n = b.cellCount();
    const target = try arena.alloc(bool, n);
    @memset(target, false);
    for (b.targets) |p| target[p] = true;
    const initial = try initialPremiums(arena, b, target);
    var walk: Traversal = .{
        .board = b,
        .target = target,
        .queue = try PremiumQueue.init(arena, n),
        .open = try arena.alloc(bool, n),
        .flag = try arena.alloc(bool, n),
        .log = .{ .arena = arena, .recording = recording },
    };
    var best: HeuristicResult = .{ .clicks = std.math.maxInt(u32) };
    for (0..8) |direction| {
        walk.reset(initial, @intCast(direction));
        try walk.chordGreedily(best.clicks);
        // Later traversals cannot replace an equal-cost earlier winner.
        if (walk.log.clicks >= best.clicks) continue;
        try walk.openRemaining();
        if (walk.log.clicks < best.clicks) best = walk.log.result();
    }
    return best;
}

fn initialPremiums(arena: Allocator, b: *const Board, target: []const bool) Allocator.Error![]i32 {
    const initial = try arena.alloc(i32, b.cellCount());
    @memset(initial, never_chord);
    for (initial, 0..) |*value, p| {
        if (b.number[p] <= 0) continue;
        value.* = -1 - @as(i32, @intFromBool(!target[p])) - b.number[p];
        for (b.neighbors[p].slice()) |q| value.* += @intFromBool(target[q]);
    }
    for (b.borders) |border| {
        for (border) |p| initial[p] += 1;
    }
    return initial;
}

const Traversal = struct {
    board: *const Board,
    target: []const bool,
    queue: PremiumQueue,
    open: []bool,
    flag: []bool,
    log: ActionLog,

    fn reset(t: *Traversal, initial: []const i32, direction: u3) void {
        t.queue.reset(t.board, initial, direction);
        @memset(t.open, false);
        @memset(t.flag, false);
        t.log = .{ .arena = t.log.arena, .recording = t.log.recording };
    }

    fn chordGreedily(t: *Traversal, bound: u32) Allocator.Error!void {
        const b = t.board;
        while (t.queue.best()) |chosen| {
            if (t.log.clicks >= bound) break;
            if (!t.open[chosen]) {
                try t.log.add(.open, chosen);
                t.reveal(chosen);
            }
            try t.flagAround(chosen);
            try t.log.add(.chord, chosen);
            for (b.neighbors[chosen].slice()) |q| {
                if (!b.mine[q]) t.reveal(q);
            }
        }
    }

    fn flagAround(t: *Traversal, chosen: u32) Allocator.Error!void {
        const b = t.board;
        const cx: i64 = b.x(chosen);
        const cy: i64 = b.y(chosen);
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i64 = -1;
            while (dy <= 1) : (dy += 1) {
                const nx = cx + dx;
                const ny = cy + dy;
                if (nx < 0 or nx >= b.width or ny < 0 or ny >= b.height) continue;
                const q: u32 = @intCast(ny * b.width + nx);
                if (!b.mine[q] or t.flag[q]) continue;
                t.flag[q] = true;
                try t.log.add(.flag, q);
                for (b.neighbors[q].slice()) |r| {
                    if (b.number[r] > 0) t.queue.change(r, 1);
                }
            }
        }
    }

    fn reveal(t: *Traversal, p: u32) void {
        const b = t.board;
        if (t.open[p]) return;
        t.open[p] = true;
        if (b.island[p]) |z| {
            for (b.zeros[z]) |q| t.open[q] = true;
            for (b.borders[z]) |q| {
                if (t.open[q]) t.queue.change(q, -1);
                t.open[q] = true;
            }
        } else if (t.target[p]) {
            for (b.neighbors[p].slice()) |q| {
                if (b.number[q] > 0) t.queue.change(q, -1);
            }
        } else {
            t.queue.change(p, 1);
        }
    }

    fn openRemaining(t: *Traversal) Allocator.Error!void {
        const b = t.board;
        if (t.log.recording == .count_only) {
            for (b.targets) |p| t.log.clicks += @intFromBool(!t.open[p]);
            for (b.zeros) |region| t.log.clicks += @intFromBool(!t.open[region[0]]);
            return;
        }
        for (0..b.width) |xx| {
            for (0..b.height) |yy| {
                const p: u32 = @intCast(yy * b.width + xx);
                if (t.open[p] or !(t.target[p] or b.number[p] == 0)) continue;
                try t.log.add(.open, p);
                t.open[p] = true;
                if (b.island[p]) |z| {
                    for (b.zeros[z]) |q| t.open[q] = true;
                }
            }
        }
    }
};
