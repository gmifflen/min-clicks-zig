const std = @import("std");
const Writer = std.Io.Writer;
const Board = @import("board.zig").Board;
const Action = @import("action.zig").Action;
const exact = @import("exact/exact.zig");
const solve_command = @import("solve_command.zig");
const Results = solve_command.Results;

pub fn writeJson(w: *Writer, board: *const Board, results: Results, witness: bool) Writer.Error!void {
    try w.print("{{\"url\":\"{f}\",\"width\":{d},\"height\":{d},\"mines\":{d},\"three_bv\":{d},\"status\":\"{s}\"", .{
        board.url(), board.width, board.height, board.mineCount(), board.bv(), status(results),
    });
    switch (results) {
        .exact => |e| try writeExactFields(w, e),
        .heuristic => |h| try w.print(",\"algorithm\":\"{s}\",\"clicks\":{d}", .{ h.algorithm.label(), h.result.clicks }),
        .all => |a| {
            try writeExactFields(w, a.exact);
            try w.print(",\"8way\":{d},\"lzini\":{d},\"hzini\":{d}", .{ a.eight_way.clicks, a.lzini.clicks, a.hzini.clicks });
        },
    }
    if (witness) try writeJsonActions(w, board, results);
    try w.writeAll("}\n");
}

fn status(results: Results) []const u8 {
    const e = results.exactResult() orelse return "heuristic";
    return if (e.stats.exact) "optimal" else "resource limit";
}

fn writeExactFields(w: *Writer, e: exact.ExactResult) Writer.Error!void {
    try w.writeAll(",\"minclicks\":");
    if (e.stats.exact) try w.print("{d}", .{e.stats.clicks}) else try w.writeAll("null");
    try w.print(",\"upper_bound\":{d},\"peak_states\":{d},\"solve_seconds\":", .{ e.stats.clicks, e.stats.peak });
    try writeGeneral(w, e.stats.elapsed, 9);
}

fn writeJsonActions(w: *Writer, board: *const Board, results: Results) Writer.Error!void {
    try w.writeAll(",\"actions\":");
    switch (results) {
        .exact => |e| try writeActionArray(w, board, e.actions),
        .heuristic => |h| try writeActionArray(w, board, h.result.actions),
        .all => |a| {
            const sequences = .{
                .{ "optimal", a.exact.actions },
                .{ "8way", a.eight_way.actions },
                .{ "lzini", a.lzini.actions },
                .{ "hzini", a.hzini.actions },
            };
            try w.writeByte('{');
            inline for (sequences, 0..) |sequence, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("\"{s}\":", .{sequence[0]});
                try writeActionArray(w, board, sequence[1]);
            }
            try w.writeByte('}');
        },
    }
}

fn writeActionArray(w: *Writer, board: *const Board, actions: []const Action) Writer.Error!void {
    try w.writeByte('[');
    for (actions, 0..) |a, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("[\"{c}\",{d},{d}]", .{ @backingInt(a.kind), board.x(a.cell), board.y(a.cell) });
    }
    try w.writeByte(']');
}

pub fn writeText(w: *Writer, board: *const Board, results: Results, witness: bool) Writer.Error!void {
    try w.print("Board: {d}x{d}, {d} mines\nURL: {f}\n3BV: {d}\n", .{ board.width, board.height, board.mineCount(), board.url(), board.bv() });
    const actions = switch (results) {
        .heuristic => |h| blk: {
            try w.print("Algorithm: {s}\nStatus: heuristic\nUpper bound clicks: {d}\n", .{ h.algorithm.label(), h.result.clicks });
            break :blk h.result.actions;
        },
        .exact => |e| blk: {
            try writeExactText(w, e);
            break :blk e.actions;
        },
        .all => |a| blk: {
            try writeExactText(w, a.exact);
            break :blk a.exact.actions;
        },
    };
    if (!witness) return;
    for (actions) |a| try w.print("Action: {c} {d} {d}\n", .{ @backingInt(a.kind), board.x(a.cell), board.y(a.cell) });
}

fn writeExactText(w: *Writer, e: exact.ExactResult) Writer.Error!void {
    const s = e.stats;
    try w.print("Candidates: {d} (removed {d})\nDP: {s}\nEngine: {t}\n", .{ e.candidates, e.removed, s.order, s.engine });
    if (s.exact) {
        try w.print("Status: optimal\nOptimal clicks: {d}\n", .{s.clicks});
    } else {
        const reason = s.reason orelse @panic("A limited search must record why it stopped");
        try w.print("Status: resource limit: {s}\nUpper bound clicks: {d}\n", .{ reason.describe(), s.clicks });
    }
    const b = e.breakdown;
    try w.print("Breakdown: {d} flags + {d} chords + {d} chains + {d} remaining 3BV\n", .{ b.flags, b.chords, b.chains, b.remaining });
    try w.print("Peak states: {d}\nTransitions: {d}\nCompleted candidates: {d}/{d}\n", .{ s.peak, s.transitions, s.completed, e.candidates });
    try w.print("Max connectivity: {d}, max factors: {d}\nFinal order: {s}\n", .{ s.max_conn, s.max_factors, s.order });
    try w.writeAll("Solve time: ");
    try writeGeneral(w, s.elapsed, 6);
    try w.print(" seconds\nDominated states: {d}\n", .{s.dominated});
}

fn writeGeneral(w: *Writer, value: f64, comptime precision: u8) Writer.Error!void {
    if (value == 0) return w.writeAll("0");
    var buffer: [64]u8 = undefined;
    const scientific = std.fmt.bufPrint(&buffer, "{e:." ++ std.fmt.comptimePrint("{d}", .{precision - 1}) ++ "}", .{value}) catch @panic("A double's scientific form exceeds 64 bytes");
    const mark = std.mem.indexOfScalar(u8, scientific, 'e') orelse @panic("Scientific form without an exponent");
    const exponent = std.fmt.parseInt(i32, scientific[mark + 1 ..], 10) catch @panic("Scientific form with a malformed exponent");
    var digits_buffer: [precision]u8 = undefined;
    const digits = significantDigits(scientific[0..mark], &digits_buffer);
    if (exponent < -4 or exponent >= precision) {
        try w.writeByte(digits[0]);
        if (digits.len > 1) try w.print(".{s}", .{digits[1..]});
        return w.print("e{c}{d:0>2}", .{ @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) });
    }
    if (exponent < 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-exponent - 1));
        return w.writeAll(digits);
    }
    const whole: usize = @intCast(exponent + 1);
    if (digits.len <= whole) {
        try w.writeAll(digits);
        return w.splatByteAll('0', whole - digits.len);
    }
    try w.print("{s}.{s}", .{ digits[0..whole], digits[whole..] });
}

fn significantDigits(mantissa: []const u8, out: []u8) []const u8 {
    var count: usize = 0;
    for (mantissa) |ch| {
        if (ch == '.') continue;
        out[count] = ch;
        count += 1;
    }
    while (count > 1 and out[count - 1] == '0') count -= 1;
    return out[0..count];
}
