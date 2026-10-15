const std = @import("std");
const Allocator = std.mem.Allocator;
const mersenne_twister = @import("mersenne_twister.zig");

const max_side = 99;

fn validDimensions(width: u32, height: u32) bool {
    return width >= 1 and height >= 1 and width <= max_side and height <= max_side;
}
const base32_alphabet = "0123456789abcdefghijklmnopqrstuv";

pub const Neighbors = struct {
    cells: [8]u32 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Neighbors) []const u32 {
        return self.cells[0..self.len];
    }
};

pub const Board = struct {
    width: u32,
    height: u32,
    mine: []const bool,
    number: []const i8,
    island: []const ?u32,
    neighbors: []const Neighbors,
    zeros: []const []const u32,
    borders: []const []const u32,
    targets: []const u32,

    pub const InitError = error{InvalidBoard} || Allocator.Error;

    /// `mine` must have width * height entries aince the board borrows it.
    pub fn init(arena: Allocator, width: u32, height: u32, mine: []const bool) InitError!Board {
        if (!validDimensions(width, height)) return error.InvalidBoard;
        if (mine.len != width * height) return error.InvalidBoard;
        const neighbors = try neighborTable(arena, width, height);
        const number = try mineCounts(arena, mine, neighbors);
        const islands = try floodZeroIslands(arena, number, neighbors);
        const sorted = try classifyNumbers(arena, number, neighbors, islands.island, islands.zeros.len);
        return .{
            .width = width,
            .height = height,
            .mine = mine,
            .number = number,
            .island = islands.island,
            .neighbors = neighbors,
            .zeros = islands.zeros,
            .borders = sorted.borders,
            .targets = sorted.targets,
        };
    }

    pub fn cellCount(board: *const Board) u32 {
        return board.width * board.height;
    }

    pub fn x(board: *const Board, cell: u32) u32 {
        return cell % board.width;
    }

    pub fn y(board: *const Board, cell: u32) u32 {
        return cell / board.width;
    }

    /// Clicks needed without chords, one per zero island plus one per target
    pub fn bv(board: *const Board) u32 {
        return @intCast(board.zeros.len + board.targets.len);
    }

    pub fn mineCount(board: *const Board) u32 {
        return @intCast(std.mem.count(bool, board.mine, &.{true}));
    }

    pub fn isTarget(board: *const Board, cell: u32) bool {
        return std.sort.binarySearch(u32, board.targets, cell, orderU32) != null;
    }

    pub fn url(board: *const Board) Url {
        return .{ .board = board };
    }

    pub const Url = struct {
        board: *const Board,

        pub fn format(self: Url, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const b = self.board;
            try w.writeAll("https://llamasweeper.com/#/game/zini-explorer?b=");
            try writeSizeCode(w, b.width, b.height);
            try w.writeAll("&m=");
            var i: usize = 0;
            while (i < b.mine.len) : (i += 5) {
                var value: u8 = 0;
                for (0..5) |j| value = 2 * value + @intFromBool(i + j < b.mine.len and b.mine[i + j]);
                try w.writeByte(base32_alphabet[value]);
            }
        }
    };
};

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

fn writeSizeCode(w: *std.Io.Writer, width: u32, height: u32) std.Io.Writer.Error!void {
    if (width == 9 and height == 9) return w.writeAll("1");
    if (width == 16 and height == 16) return w.writeAll("2");
    if (width == 30 and height == 16) return w.writeAll("3");
    if (width < 10 and height < 10) return w.print("{d}{d}", .{ width, height });
    try w.print("{d:0>2}{d:0>2}", .{ width, height });
}

fn neighborTable(arena: Allocator, width: u32, height: u32) Allocator.Error![]Neighbors {
    const table = try arena.alloc(Neighbors, width * height);
    for (table, 0..) |*entry, p| {
        entry.* = .{};
        const px: i64 = @intCast(p % width);
        const py: i64 = @intCast(p / width);
        var dy: i64 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i64 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = px + dx;
                const ny = py + dy;
                if ((dx == 0 and dy == 0) or nx < 0 or ny < 0 or nx >= width or ny >= height) continue;
                entry.cells[entry.len] = @intCast(ny * width + nx);
                entry.len += 1;
            }
        }
    }
    return table;
}

fn mineCounts(arena: Allocator, mine: []const bool, neighbors: []const Neighbors) Allocator.Error![]i8 {
    const number = try arena.alloc(i8, mine.len);
    for (number, 0..) |*value, p| {
        if (mine[p]) {
            value.* = -1;
            continue;
        }
        var count: i8 = 0;
        for (neighbors[p].slice()) |q| count += @intFromBool(mine[q]);
        value.* = count;
    }
    return number;
}

const ZeroIslands = struct { island: []?u32, zeros: [][]u32 };

fn floodZeroIslands(arena: Allocator, number: []const i8, neighbors: []const Neighbors) Allocator.Error!ZeroIslands {
    const island = try arena.alloc(?u32, number.len);
    @memset(island, null);
    var zeros: std.ArrayList([]u32) = .empty;
    for (0..number.len) |start| {
        if (number[start] != 0 or island[start] != null) continue;
        const id: u32 = @intCast(zeros.items.len);
        var members: std.ArrayList(u32) = .empty;
        try members.append(arena, @intCast(start));
        island[start] = id;
        var i: usize = 0;
        while (i < members.items.len) : (i += 1) {
            for (neighbors[members.items[i]].slice()) |q| {
                if (number[q] != 0 or island[q] != null) continue;
                island[q] = id;
                try members.append(arena, q);
            }
        }
        try zeros.append(arena, members.items);
    }
    return .{ .island = island, .zeros = zeros.items };
}

const NumberClasses = struct { borders: [][]u32, targets: []u32 };

/// Cells are visited in ascending order,
/// so each border list is built sorted and a duplicate can only be the most recent entry
fn classifyNumbers(
    arena: Allocator,
    number: []const i8,
    neighbors: []const Neighbors,
    island: []const ?u32,
    island_count: usize,
) Allocator.Error!NumberClasses {
    const borders = try arena.alloc(std.ArrayList(u32), island_count);
    @memset(borders, .empty);
    var targets: std.ArrayList(u32) = .empty;
    for (0..number.len) |p| {
        if (number[p] <= 0) continue;
        const cell: u32 = @intCast(p);
        var touches_zero = false;
        for (neighbors[p].slice()) |q| {
            const z = island[q] orelse continue;
            touches_zero = true;
            const list = &borders[z];
            if (list.items.len == 0 or list.items[list.items.len - 1] != cell) try list.append(arena, cell);
        }
        if (!touches_zero) try targets.append(arena, cell);
    }
    const slices = try arena.alloc([]u32, island_count);
    for (slices, borders) |*out, list| out.* = list.items;
    return .{ .borders = slices, .targets = targets.items };
}

pub const DecodeError = error{
    MissingSizeParameter,
    MissingMineParameter,
    InvalidSize,
    DimensionsOutOfRange,
    MineEncodingTooShort,
    InvalidMineEncoding,
} || Board.InitError;

pub fn decode(arena: Allocator, text: []const u8) DecodeError!Board {
    const size = parameter(text, "b") orelse return error.MissingSizeParameter;
    const encoded = parameter(text, "m") orelse return error.MissingMineParameter;
    const dims = try decodeSize(size);
    if (!validDimensions(dims.width, dims.height)) return error.DimensionsOutOfRange;
    const cells = dims.width * dims.height;
    if (encoded.len * 5 < cells) return error.MineEncodingTooShort;
    const mine = try arena.alloc(bool, cells);
    var filled: usize = 0;
    for (encoded) |c| {
        const value = std.mem.indexOfScalar(u8, base32_alphabet, c) orelse return error.InvalidMineEncoding;
        var bit: u3 = 5;
        while (bit > 0 and filled < cells) {
            bit -= 1;
            mine[filled] = (value >> bit) & 1 == 1;
            filled += 1;
        }
    }
    return Board.init(arena, dims.width, dims.height, mine);
}

fn parameter(text: []const u8, comptime name: []const u8) ?[]const u8 {
    inline for (.{ "?", "&" }) |delimiter| {
        const prefix = delimiter ++ name ++ "=";
        if (std.mem.indexOf(u8, text, prefix)) |found| {
            const start = found + prefix.len;
            const end = std.mem.indexOfAnyPos(u8, text, start, "&#") orelse text.len;
            return text[start..end];
        }
    }
    return null;
}

const Dimensions = struct { width: u32, height: u32 };

fn decodeSize(code: []const u8) error{InvalidSize}!Dimensions {
    if (std.mem.eql(u8, code, "1")) return .{ .width = 9, .height = 9 };
    if (std.mem.eql(u8, code, "2")) return .{ .width = 16, .height = 16 };
    if (std.mem.eql(u8, code, "3")) return .{ .width = 30, .height = 16 };
    if (code.len != 2 and code.len != 4) return error.InvalidSize;
    const half = code.len / 2;
    return .{ .width = try digits(code[0..half]), .height = try digits(code[half..]) };
}

fn digits(text: []const u8) error{InvalidSize}!u32 {
    var value: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidSize;
        value = value * 10 + (c - '0');
    }
    return value;
}

pub const RandomError = error{InvalidRandomParameters} || Board.InitError;

pub fn random32(arena: Allocator, width: u32, height: u32, mines: u32, seed: u32) RandomError!Board {
    var rng = mersenne_twister.Mt19937.init(seed);
    return randomWith(arena, width, height, mines, &rng);
}

pub fn random64(arena: Allocator, width: u32, height: u32, mines: u32, seed: u64) RandomError!Board {
    var rng = mersenne_twister.Mt19937_64.init(seed);
    return randomWith(arena, width, height, mines, &rng);
}

fn randomWith(arena: Allocator, width: u32, height: u32, mines: u32, rng: anytype) RandomError!Board {
    const Word = @TypeOf(rng.*).Word;
    if (!validDimensions(width, height) or mines > width * height) return error.InvalidRandomParameters;
    const cells = width * height;
    const order = try arena.alloc(u32, cells);
    for (order, 0..) |*value, i| value.* = @intCast(i);
    var i: usize = cells - 1;
    while (i > 0) : (i -= 1) {
        const bound: Word = @intCast(i + 1);
        const threshold = (0 -% bound) % bound;
        var draw = rng.next();
        while (draw < threshold) draw = rng.next();
        std.mem.swap(u32, &order[i], &order[@intCast(draw % bound)]);
    }
    const mine = try arena.alloc(bool, cells);
    @memset(mine, false);
    for (order[0..mines]) |cell| mine[cell] = true;
    return Board.init(arena, width, height, mine);
}
