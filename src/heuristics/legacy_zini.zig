const std = @import("std");
const Allocator = std.mem.Allocator;
const Board = @import("../board.zig").Board;
const action = @import("../action.zig");
const ActionLog = action.ActionLog;
const HeuristicResult = action.HeuristicResult;

pub const LegacyResults = struct {
    hzini: HeuristicResult,
    lzini: HeuristicResult,
};

pub fn hzini(arena: Allocator, board: *const Board, recording: action.Recording) Allocator.Error!HeuristicResult {
    const legacy = try LegacyBoard.init(arena, board);
    return run(arena, &legacy, .regions_opened_first, recording);
}

pub fn legacyZini(arena: Allocator, board: *const Board, recording: action.Recording) Allocator.Error!LegacyResults {
    const legacy = try LegacyBoard.init(arena, board);
    const h = try run(arena, &legacy, .regions_opened_first, recording);
    const raw = try run(arena, &legacy, .interleaved, recording);
    return .{ .hzini = h, .lzini = if (raw.clicks > h.clicks) h else raw };
}

const Variant = enum { regions_opened_first, interleaved };

const never_chord = -100;

const LegacyBoard = struct {
    board: *const Board,
    order: []const u32,
    primary: []const u32,
    secondary: []const u32,
    openings: []const []const u32,

    fn init(arena: Allocator, board: *const Board) Allocator.Error!LegacyBoard {
        const order = try columnMajorOrder(arena, board);
        const labels = try labelRegions(arena, board, order);
        return .{
            .board = board,
            .order = order,
            .primary = labels.primary,
            .secondary = labels.secondary,
            .openings = try regionOpenings(arena, order, labels),
        };
    }
};

fn columnMajorOrder(arena: Allocator, board: *const Board) Allocator.Error![]const u32 {
    const order = try arena.alloc(u32, board.cellCount());
    var k: usize = 0;
    for (0..board.width) |x| {
        for (0..board.height) |y| {
            order[k] = @intCast(y * board.width + x);
            k += 1;
        }
    }
    return order;
}

const RegionLabels = struct { primary: []const u32, secondary: []const u32, count: usize };

fn labelRegions(arena: Allocator, board: *const Board, order: []const u32) Allocator.Error!RegionLabels {
    const labels = try arena.alloc(u32, board.zeros.len);
    @memset(labels, 0);
    var by_label: std.ArrayList(u32) = .empty;
    for (order) |p| {
        const z = board.island[p] orelse continue;
        if (labels[z] != 0) continue;
        try by_label.append(arena, z);
        labels[z] = @intCast(by_label.items.len);
    }
    const primary = try arena.alloc(u32, board.cellCount());
    const secondary = try arena.alloc(u32, board.cellCount());
    @memset(primary, 0);
    @memset(secondary, 0);
    for (by_label.items) |z| {
        for (board.zeros[z]) |p| primary[p] = labels[z];
        for (board.borders[z]) |p| {
            if (primary[p] == 0) primary[p] = labels[z] else secondary[p] = labels[z];
        }
    }
    return .{ .primary = primary, .secondary = secondary, .count = by_label.items.len };
}

fn regionOpenings(arena: Allocator, order: []const u32, labels: RegionLabels) Allocator.Error![]const []const u32 {
    const openings = try arena.alloc(std.ArrayList(u32), labels.count + 1);
    @memset(openings, .empty);
    for (order) |p| {
        const primary = labels.primary[p];
        const secondary = labels.secondary[p];
        if (primary != 0) try openings[primary].append(arena, p);
        if (secondary != 0 and secondary != primary) try openings[secondary].append(arena, p);
    }
    const slices = try arena.alloc([]const u32, openings.len);
    for (slices, openings) |*out, list| out.* = list.items;
    return slices;
}

const Position = struct {
    open: []bool,
    flag: []bool,
    premium: []i32,

    fn init(arena: Allocator, n: usize) Allocator.Error!Position {
        const position: Position = .{
            .open = try arena.alloc(bool, n),
            .flag = try arena.alloc(bool, n),
            .premium = try arena.alloc(i32, n),
        };
        @memset(position.open, false);
        @memset(position.flag, false);
        @memset(position.premium, 0);
        return position;
    }

    fn copyFrom(self: Position, other: Position) void {
        @memcpy(self.open, other.open);
        @memcpy(self.flag, other.flag);
        @memcpy(self.premium, other.premium);
    }
};

fn run(arena: Allocator, lb: *const LegacyBoard, variant: Variant, recording: action.Recording) Allocator.Error!HeuristicResult {
    const b = lb.board;
    const n = b.cellCount();
    const regions_first = variant == .regions_opened_first;
    const s = try Position.init(arena, n);
    const scratch = try Position.init(arena, n);
    var log: ActionLog = .{ .arena = arena, .recording = recording };
    var remaining: i64 = n - b.mineCount();
    if (regions_first) remaining -= try openAllRegions(lb, s, &log);
    setInitialPremiums(lb, s);
    var openings_done = regions_first;
    while (remaining > 0) {
        const candidates = best(lb, s, regions_first);
        if (candidates.premium >= 0 and candidates.count > 0) {
            const chosen = try breakTie(lb, s, scratch, candidates, regions_first);
            remaining -= try chord(lb, s, chosen, &log);
        } else {
            const chosen = nextOpening(lb, s, &openings_done);
            remaining -= reveal(lb, s, chosen);
            try log.add(.open, chosen);
        }
    }
    return log.result();
}

fn openAllRegions(lb: *const LegacyBoard, s: Position, log: *ActionLog) Allocator.Error!u32 {
    const b = lb.board;
    const clicked = try log.arena.alloc(bool, b.zeros.len + 1);
    @memset(clicked, false);
    var opened: u32 = 0;
    for (lb.order) |p| {
        const label = lb.primary[p];
        if (label == 0) continue;
        s.open[p] = true;
        opened += 1;
        if (b.number[p] == 0 and !clicked[label]) {
            clicked[label] = true;
            try log.add(.open, p);
        }
    }
    return opened;
}

fn setInitialPremiums(lb: *const LegacyBoard, s: Position) void {
    const b = lb.board;
    for (lb.order) |p| {
        if (b.number[p] <= 0) {
            s.premium[p] = never_chord;
            continue;
        }
        var value: i32 = -@as(i32, @intFromBool(!s.open[p])) - 1 + @intFromBool(lb.primary[p] == 0);
        var unopened_zero = false;
        for (b.neighbors[p].slice()) |q| {
            if (b.mine[q]) {
                value -= @intFromBool(!s.flag[q]);
            } else if (!s.open[q] and lb.primary[q] == 0) {
                value += 1;
            }
            if (b.number[q] == 0 and !s.open[q]) unopened_zero = true;
        }
        s.premium[p] = value + @intFromBool(lb.secondary[p] != 0 and unopened_zero);
    }
}

fn reveal(lb: *const LegacyBoard, s: Position, p: u32) u32 {
    const b = lb.board;
    s.open[p] = true;
    var count: u32 = 1;
    if (b.number[p] == 0) {
        for (lb.openings[lb.primary[p]]) |q| {
            if (q == p) continue;
            if (!s.open[q]) {
                s.open[q] = true;
                count += 1;
                if (b.number[q] != 0) s.premium[q] += 1;
            }
            if (b.number[q] != 0) s.premium[q] -= 1;
        }
        return count;
    }
    s.premium[p] += 1;
    if (lb.primary[p] == 0) {
        s.premium[p] -= 1;
        for (b.neighbors[p].slice()) |q| s.premium[q] -= 1;
    }
    return count;
}

fn chord(lb: *const LegacyBoard, s: Position, p: u32, log: ?*ActionLog) Allocator.Error!u32 {
    const b = lb.board;
    var revealed: u32 = 0;
    if (!s.open[p]) {
        revealed += reveal(lb, s, p);
        if (log) |l| try l.add(.open, p);
    }
    for (b.neighbors[p].slice()) |q| {
        if (b.mine[q] and !s.flag[q]) {
            s.flag[q] = true;
            for (b.neighbors[q].slice()) |r| s.premium[r] += 1;
            if (log) |l| try l.add(.flag, q);
        } else if (!b.mine[q] and !s.open[q]) {
            revealed += reveal(lb, s, q);
        }
    }
    if (log) |l| try l.add(.chord, p);
    return revealed;
}

const Best = struct { premium: i32 = never_chord, count: u32 = 0, first: u32 = 0 };

fn best(lb: *const LegacyBoard, s: Position, open_only: bool) Best {
    var result: Best = .{};
    for (lb.order) |p| {
        if (open_only and !s.open[p]) continue;
        if (s.premium[p] > result.premium) {
            result.premium = s.premium[p];
            result.count = 0;
        }
        if (s.premium[p] == result.premium) {
            if (result.count == 0) result.first = p;
            result.count += 1;
        }
    }
    return result;
}

fn breakTie(lb: *const LegacyBoard, s: Position, scratch: Position, candidates: Best, open_only: bool) Allocator.Error!u32 {
    if (candidates.count <= 1) return candidates.first;
    var chosen = candidates.first;
    var score: i64 = -1;
    for (lb.order) |p| {
        if ((open_only and !s.open[p]) or s.premium[p] != candidates.premium) continue;
        scratch.copyFrom(s);
        _ = try chord(lb, scratch, p, null);
        const future = best(lb, scratch, open_only);
        const value = @as(i64, future.premium) * 1000 + future.count;
        if (value > score) {
            score = value;
            chosen = p;
        }
    }
    return chosen;
}

fn nextOpening(lb: *const LegacyBoard, s: Position, openings_done: *bool) u32 {
    const b = lb.board;
    if (!openings_done.*) {
        for (lb.order) |p| {
            if (!s.open[p] and b.number[p] == 0) return p;
        }
        openings_done.* = true;
    }
    for (lb.order) |p| {
        if (!s.open[p] and !b.mine[p] and !(lb.secondary[p] != 0 and b.number[p] > 0)) return p;
    }
    @panic("Legacy ZiNi left an unopened cell");
}
