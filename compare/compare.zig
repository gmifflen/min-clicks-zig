//! Runs the solver and the C++ reference on the same boards. Both must
//! describe the same boards, find the same click counts and print the same
//! output layout; their statistics, witnesses and times may differ. Prints
//! each program's time per board family and exits with 1 on any disagreement.
//!
//! Usage: compare SOLVER REFERENCE [--rounds N] [--quick] [--no-color]
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Mode = enum {
    /// Solved to optimality with all four algorithms; compared by time.
    solve,
    /// Too hard to finish: stopped after five seconds and compared by the
    /// upper bound reached, lower being better.
    limited,
    /// Too hard to finish: stopped at once, so the time is model building
    /// and planning, which some boards spend seconds on.
    setup,

    fn arguments(mode: Mode) []const []const u8 {
        return switch (mode) {
            .solve => &.{ "--all", "--time-limit", "300" },
            .limited => &.{ "--json", "--quiet", "--time-limit", "5" },
            .setup => &.{ "--json", "--quiet", "--time-limit", "1e-9" },
        };
    }
};

const BoardSpec = struct { width: u32, height: u32, mines: u32, seed: u32 };

const Family = struct { name: []const u8, mode: Mode, boards: []const BoardSpec };

const full_corpus = [_]Family{
    .{ .name = "small 16x16/40", .mode = .solve, .boards = &seeds(16, 16, 40, 10) },
    .{ .name = "expert 30x16/99", .mode = .solve, .boards = &seeds(30, 16, 99, 20) },
    .{ .name = "large 40x24/200", .mode = .solve, .boards = &seeds(40, 24, 200, 5) },
    .{ .name = "long 46x28/270", .mode = .solve, .boards = &.{
        .{ .width = 46, .height = 28, .mines = 270, .seed = 3 },
    } },
    .{ .name = "hard 30x30/180", .mode = .solve, .boards = &seeds(30, 30, 180, 3) },
    .{ .name = "island 99x99 (just setup)", .mode = .setup, .boards = &.{
        .{ .width = 99, .height = 99, .mines = 500, .seed = 0 },
        .{ .width = 99, .height = 99, .mines = 1000, .seed = 0 },
        .{ .width = 99, .height = 99, .mines = 1500, .seed = 2 },
    } },
};

const quick_corpus = [_]Family{
    .{ .name = "small 16x16/40", .mode = .solve, .boards = &seeds(16, 16, 40, 3) },
    .{ .name = "expert 30x16/99", .mode = .solve, .boards = &seeds(30, 16, 99, 3) },
};

fn seeds(comptime width: u32, comptime height: u32, comptime mines: u32, comptime count: u32) [count]BoardSpec {
    var boards: [count]BoardSpec = undefined;
    for (&boards, 0..) |*board, seed| board.* = .{ .width = width, .height = height, .mines = mines, .seed = seed };
    return boards;
}

/// JSON values that legitimately differ between the two solvers.
const volatile_json_keys = [_][]const u8{ "peak_states", "solve_seconds" };
/// When a limit stops the search, the click counts reached differ too.
const volatile_limited_keys = [_][]const u8{ "minclicks", "upper_bound" };
/// Text lines whose values depend on how the search ran, not on the board.
const volatile_text_labels = [_][]const u8{
    "Candidates",
    "DP",
    "Engine",
    "Breakdown",
    "Peak states",
    "Transitions",
    "Completed candidates",
    "Max connectivity",
    "Final order",
    "Solve time",
    "Dominated states",
};

const Options = struct { solver: []const u8, reference: []const u8, rounds: u32 = 3, quick: bool = false, color: bool = true };

const Tone = enum { heading, good, bad, muted };

const Palette = struct {
    enabled: bool,

    fn start(p: Palette, tone: Tone) []const u8 {
        if (!p.enabled) return "";
        return switch (tone) {
            .heading => "\x1b[1;36m",
            .good => "\x1b[32m",
            .bad => "\x1b[31m",
            .muted => "\x1b[2m",
        };
    }

    fn reset(p: Palette) []const u8 {
        return if (p.enabled) "\x1b[0m" else "";
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const options = parseOptions(try init.minimal.args.toSlice(arena)) orelse {
        std.debug.print("Usage: compare SOLVER REFERENCE [--rounds N] [--quick] [--no-color]\n", .{});
        return 1;
    };
    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    var comparison: Comparison = .{ .gpa = init.gpa, .io = init.io, .out = &stdout.interface, .options = options, .palette = .{ .enabled = options.color } };
    const corpus: []const Family = if (options.quick) &quick_corpus else &full_corpus;
    const totals = try arena.alloc(FamilyTotals, corpus.len);
    for (totals) |*family| family.* = try .init(arena, options.rounds);
    try comparison.out.print("{s}MIN-CLICKS COMPARISON{s}\n", .{ comparison.palette.start(.heading), comparison.palette.reset() });
    for (0..options.rounds) |round| {
        try comparison.out.print("\n{s}Round {d}/{d}{s}\n", .{ comparison.palette.start(.heading), round + 1, options.rounds, comparison.palette.reset() });
        try comparison.out.flush();
        for (corpus, totals) |family, *total| try comparison.runFamily(family, round, total);
    }
    try writeSummary(comparison.out, comparison.palette, corpus, totals);
    const result_tone: Tone = if (comparison.disagreements == 0) .good else .bad;
    try comparison.out.print("\n{s}{d} disagreements{s}\n", .{ comparison.palette.start(result_tone), comparison.disagreements, comparison.palette.reset() });
    try comparison.out.flush();
    return if (comparison.disagreements == 0) 0 else 1;
}

fn parseOptions(args: []const []const u8) ?Options {
    if (args.len < 3) return null;
    var options: Options = .{ .solver = args[1], .reference = args[2] };
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--quick")) {
            options.quick = true;
            options.rounds = 1;
        } else if (std.mem.eql(u8, args[i], "--no-color")) {
            options.color = false;
        } else if (std.mem.eql(u8, args[i], "--rounds") and i + 1 < args.len) {
            i += 1;
            options.rounds = std.fmt.parseInt(u32, args[i], 10) catch return null;
            if (options.rounds == 0) return null;
        } else return null;
    }
    return options;
}

/// Per round: summed seconds, or summed upper bounds for limited families.
const FamilyTotals = struct {
    reference: []f64,
    solver: []f64,

    fn init(arena: Allocator, rounds: u32) Allocator.Error!FamilyTotals {
        const totals: FamilyTotals = .{ .reference = try arena.alloc(f64, rounds), .solver = try arena.alloc(f64, rounds) };
        @memset(totals.reference, 0);
        @memset(totals.solver, 0);
        return totals;
    }
};

const Comparison = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    options: Options,
    palette: Palette,
    disagreements: u32 = 0,

    fn runFamily(c: *Comparison, family: Family, round: usize, totals: *FamilyTotals) !void {
        const disagreements_before = c.disagreements;
        for (family.boards, 0..) |board, index| {
            var args: Arguments = .{};
            const pair = try c.runPair(args.forBoard(board, family.mode.arguments()), (round + index) % 2 == 0);
            defer pair.deinit(c.gpa);
            try c.checkAgreement(family, board, pair.reference, pair.solver);
            totals.reference[round] += measure(family.mode, pair.reference);
            totals.solver[round] += measure(family.mode, pair.solver);
            if (family.mode == .solve and index == 0 and round == 0) try c.checkTextLayout(board);
        }
        const passed = c.disagreements == disagreements_before;
        try c.out.print("  {s}{s}{s}  ", .{ c.palette.start(if (passed) .good else .bad), if (passed) "PASS" else "FAIL", c.palette.reset() });
        try writeResultRow(c.out, c.palette, family.name, family.mode, totals.reference[round], totals.solver[round]);
        try c.out.flush();
    }

    /// Callers alternate `reference_first` so neither program always meets
    /// the warmer machine.
    fn runPair(c: *Comparison, args: []const []const u8, reference_first: bool) !Pair {
        if (reference_first) {
            const reference = try c.run(c.options.reference, args);
            errdefer c.gpa.free(reference.stdout);
            return .{ .reference = reference, .solver = try c.run(c.options.solver, args) };
        }
        const solver = try c.run(c.options.solver, args);
        errdefer c.gpa.free(solver.stdout);
        return .{ .reference = try c.run(c.options.reference, args), .solver = solver };
    }

    fn run(c: *Comparison, program: []const u8, args: []const []const u8) !Run {
        var argv: [16][]const u8 = undefined;
        argv[0] = program;
        @memcpy(argv[1..][0..args.len], args);
        const started: Io.Timestamp = .now(c.io, .awake);
        const result = try std.process.run(c.gpa, c.io, .{ .argv = argv[0 .. args.len + 1] });
        const elapsed = started.untilNow(c.io, .awake);
        c.gpa.free(result.stderr);
        const exit_code: u8 = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        return .{ .stdout = result.stdout, .exit_code = exit_code, .seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s };
    }

    fn checkAgreement(c: *Comparison, family: Family, board: BoardSpec, reference: Run, solver: Run) !void {
        if (reference.exit_code != solver.exit_code) return c.disagree(board, "exit codes differ", reference.stdout, solver.stdout);
        if (reference.exit_code == 1) return c.disagree(board, "both programs failed", reference.stdout, solver.stdout);
        const reference_masked = try maskJson(c.gpa, reference.stdout, family.mode);
        defer c.gpa.free(reference_masked);
        const solver_masked = try maskJson(c.gpa, solver.stdout, family.mode);
        defer c.gpa.free(solver_masked);
        if (!std.mem.eql(u8, reference_masked, solver_masked)) try c.disagree(board, "outputs differ beyond statistics", reference.stdout, solver.stdout);
    }

    /// The text layout is compared once per family, on its first board.
    fn checkTextLayout(c: *Comparison, board: BoardSpec) !void {
        var args: Arguments = .{};
        const pair = try c.runPair(args.forBoard(board, &.{"--quiet"}), true);
        defer pair.deinit(c.gpa);
        const reference_masked = try maskText(c.gpa, pair.reference.stdout);
        defer c.gpa.free(reference_masked);
        const solver_masked = try maskText(c.gpa, pair.solver.stdout);
        defer c.gpa.free(solver_masked);
        if (!std.mem.eql(u8, reference_masked, solver_masked)) try c.disagree(board, "text layouts differ", pair.reference.stdout, pair.solver.stdout);
    }

    fn disagree(c: *Comparison, board: BoardSpec, what: []const u8, reference: []const u8, solver: []const u8) !void {
        c.disagreements += 1;
        try c.out.print("\n{s}DISAGREEMENT{s} on --random {d} {d} {d} {d}: {s}\n  reference: {s}\n  solver:    {s}\n", .{ c.palette.start(.bad), c.palette.reset(), board.width, board.height, board.mines, board.seed, what, reference, solver });
    }
};

const Run = struct { stdout: []u8, exit_code: u8, seconds: f64 };

const Pair = struct {
    reference: Run,
    solver: Run,

    fn deinit(pair: Pair, gpa: Allocator) void {
        gpa.free(pair.reference.stdout);
        gpa.free(pair.solver.stdout);
    }
};

/// Seconds, or for limited families the upper bound reached (zero when a
/// failed run printed none).
fn measure(mode: Mode, run_result: Run) f64 {
    if (mode != .limited) return run_result.seconds;
    const bound = jsonValue(run_result.stdout, "upper_bound") orelse return 0;
    return std.fmt.parseFloat(f64, bound) catch 0;
}

/// Command-line arguments for one board, built in fixed storage.
const Arguments = struct {
    storage: [4][16]u8 = undefined,
    list: [12][]const u8 = undefined,

    fn forBoard(a: *Arguments, board: BoardSpec, extra: []const []const u8) []const []const u8 {
        a.list[0] = "--random";
        for ([_]u32{ board.width, board.height, board.mines, board.seed }, 0..) |value, i| {
            a.list[1 + i] = std.fmt.bufPrint(&a.storage[i], "{d}", .{value}) catch @panic("A board number exceeds 16 digits");
        }
        @memcpy(a.list[5..][0..extra.len], extra);
        return a.list[0 .. 5 + extra.len];
    }
};

/// The text of a JSON value, up to the next comma or closing brace.
fn jsonValue(json: []const u8, key: []const u8) ?[]const u8 {
    var quoted: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&quoted, "\"{s}\":", .{key}) catch @panic("A JSON key exceeds 60 bytes");
    const at = std.mem.indexOf(u8, json, label) orelse return null;
    const value = json[at + label.len ..];
    return value[0 .. std.mem.indexOfAny(u8, value, ",}") orelse value.len];
}

/// `json` with the values of the volatile keys replaced by `*`.
fn maskJson(gpa: Allocator, json: []const u8, mode: Mode) Allocator.Error![]u8 {
    var masked = try normalizeLineEndings(gpa, json);
    errdefer gpa.free(masked);
    for (volatile_json_keys) |key| masked = try replaceValue(gpa, masked, key);
    if (mode == .solve) return masked;
    for (volatile_limited_keys) |key| masked = try replaceValue(gpa, masked, key);
    return masked;
}

fn replaceValue(gpa: Allocator, json: []u8, key: []const u8) Allocator.Error![]u8 {
    const value = jsonValue(json, key) orelse return json;
    const begin = @intFromPtr(value.ptr) - @intFromPtr(json.ptr);
    const replaced = try std.mem.concat(gpa, u8, &.{ json[0..begin], "*", json[begin + value.len ..] });
    gpa.free(json);
    return replaced;
}

/// `text` with the values of volatile lines replaced by `*`.
fn maskText(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const normalized = try normalizeLineEndings(gpa, text);
    defer gpa.free(normalized);
    var masked: std.ArrayList(u8) = .empty;
    errdefer masked.deinit(gpa);
    var lines = std.mem.splitScalar(u8, normalized, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const label = line[0 .. colon orelse line.len];
        const is_volatile = colon != null and isVolatileLabel(label);
        try masked.appendSlice(gpa, if (is_volatile) label else line);
        if (is_volatile) try masked.appendSlice(gpa, ": *");
        try masked.append(gpa, '\n');
    }
    return masked.toOwnedSlice(gpa);
}

/// Windows C++ text streams emit CRLF; Zig writes LF directly.
fn normalizeLineEndings(gpa: Allocator, output: []const u8) Allocator.Error![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(gpa);
    for (output, 0..) |ch, i| {
        if (ch == '\r' and i + 1 < output.len and output[i + 1] == '\n') continue;
        try normalized.append(gpa, ch);
    }
    return normalized.toOwnedSlice(gpa);
}

fn isVolatileLabel(label: []const u8) bool {
    for (volatile_text_labels) |volatile_label| {
        if (std.mem.eql(u8, label, volatile_label)) return true;
    }
    return false;
}

fn writeSummary(out: *Io.Writer, palette: Palette, corpus: []const Family, totals: []const FamilyTotals) Io.Writer.Error!void {
    try out.print("\n{s}SUMMARY{s}  (median of round totals)\n\n", .{ palette.start(.heading), palette.reset() });
    try out.print("{s:<27} {s:>13} {s:>13}   {s}\n", .{ "Family", "Reference", "Solver", "Solver advantage" });
    try out.print("{s}-------------------------------------------------------------------------------{s}\n", .{ palette.start(.muted), palette.reset() });
    for (corpus, totals) |family, total| {
        try writeResultRow(out, palette, family.name, family.mode, median(total.reference), median(total.solver));
    }
}

fn writeResultRow(out: *Io.Writer, palette: Palette, name: []const u8, mode: Mode, reference: f64, solver: f64) Io.Writer.Error!void {
    var reference_buffer: [32]u8 = undefined;
    var solver_buffer: [32]u8 = undefined;
    var advantage_buffer: [48]u8 = undefined;
    const reference_label = formatMeasure(&reference_buffer, mode, reference);
    const solver_label = formatMeasure(&solver_buffer, mode, solver);
    const advantage = formatAdvantage(&advantage_buffer, mode, reference, solver);
    const tone: Tone = if (solver < reference) .good else if (solver > reference) .bad else .muted;
    try out.print("{s:<27} {s:>13} {s:>13}   {s}{s}{s}\n", .{ name, reference_label, solver_label, palette.start(tone), advantage, palette.reset() });
}

fn formatMeasure(buffer: []u8, mode: Mode, value: f64) []const u8 {
    if (mode == .limited) return std.fmt.bufPrint(buffer, "{d:.0} clicks", .{value}) catch @panic("A click bound exceeds its display buffer");
    if (value < 1) return std.fmt.bufPrint(buffer, "{d:.1} ms", .{value * 1000}) catch @panic("Milliseconds exceed their display buffer");
    return std.fmt.bufPrint(buffer, "{d:.2} s", .{value}) catch @panic("Seconds exceed their display buffer");
}

/// Ratios always show a magnitude of at least one, with direction in words.
fn formatAdvantage(buffer: []u8, mode: Mode, reference: f64, solver: f64) []const u8 {
    if (reference == solver) return "same";
    if (mode == .limited) {
        const direction = if (solver < reference) "fewer" else "more";
        return std.fmt.bufPrint(buffer, "{d:.0} {s} clicks", .{ @abs(reference - solver), direction }) catch @panic("A bound difference exceeds its display buffer");
    }
    if (reference <= 0 or solver <= 0) return "n/a";
    const faster = solver < reference;
    const ratio = if (faster) reference / solver else solver / reference;
    return std.fmt.bufPrint(buffer, "{d:.2}x {s}", .{ ratio, if (faster) "faster" else "slower" }) catch @panic("A speed ratio exceeds its display buffer");
}

/// Sorts `values` in place.
fn median(values: []f64) f64 {
    std.mem.sortUnstable(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    return if (values.len % 2 == 1) values[middle] else (values[middle - 1] + values[middle]) / 2;
}

const testing = std.testing;

test "statistics are masked and everything else is kept" {
    const cases = [_]struct { mode: Mode, json: []const u8, expected: []const u8 }{
        .{ .mode = .solve, .json = "{\"minclicks\":12,\"upper_bound\":12,\"peak_states\":13,\"solve_seconds\":1e-05}", .expected = "{\"minclicks\":12,\"upper_bound\":12,\"peak_states\":*,\"solve_seconds\":*}" },
        .{ .mode = .limited, .json = "{\"minclicks\":null,\"upper_bound\":61,\"peak_states\":2,\"solve_seconds\":0.5,\"8way\":46}", .expected = "{\"minclicks\":*,\"upper_bound\":*,\"peak_states\":*,\"solve_seconds\":*,\"8way\":46}" },
    };
    for (cases) |case| {
        const masked = try maskJson(testing.allocator, case.json, case.mode);
        defer testing.allocator.free(masked);
        try testing.expectEqualStrings(case.expected, masked);
    }
    const text = try maskText(testing.allocator, "3BV: 31\nPeak states: 13\nOptimal clicks: 12\n");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("3BV: 31\nPeak states: *\nOptimal clicks: 12\n\n", text);
}

test "line ending normalization preserves other bytes" {
    const cases = [_]struct { output: []const u8, expected: []const u8 }{
        .{ .output = "", .expected = "" },
        .{ .output = "one\ntwo\n", .expected = "one\ntwo\n" },
        .{ .output = "one\r\ntwo\r\n", .expected = "one\ntwo\n" },
        .{ .output = "one\r\ntwo\nthree", .expected = "one\ntwo\nthree" },
        .{ .output = "one\rtwo\r", .expected = "one\rtwo\r" },
    };
    for (cases) |case| {
        const normalized = try normalizeLineEndings(testing.allocator, case.output);
        defer testing.allocator.free(normalized);
        try testing.expectEqualStrings(case.expected, normalized);
    }
}

test "JSON comparison accepts Windows statistics but rejects result changes" {
    const reference = "{\"status\":\"optimal\",\"minclicks\":43,\"upper_bound\":43,\"peak_states\":56,\"solve_seconds\":0.000936,\"8way\":46}\r\n";
    const cases = [_]struct { mode: Mode, solver: []const u8, agrees: bool }{
        .{ .mode = .solve, .solver = "{\"status\":\"optimal\",\"minclicks\":43,\"upper_bound\":43,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":46}\n", .agrees = true },
        .{ .mode = .solve, .solver = "{\"status\":\"optimal\",\"minclicks\":44,\"upper_bound\":44,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":46}\n", .agrees = false },
        .{ .mode = .solve, .solver = "{\"status\":\"optimal\",\"minclicks\":43,\"upper_bound\":43,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":47}\n", .agrees = false },
        .{ .mode = .limited, .solver = "{\"status\":\"optimal\",\"minclicks\":44,\"upper_bound\":44,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":46}\n", .agrees = true },
        .{ .mode = .setup, .solver = "{\"status\":\"optimal\",\"minclicks\":44,\"upper_bound\":44,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":46}\n", .agrees = true },
        .{ .mode = .limited, .solver = "{\"status\":\"resource limit\",\"minclicks\":null,\"upper_bound\":44,\"peak_states\":143,\"solve_seconds\":0.0006674,\"8way\":46}\n", .agrees = false },
    };
    for (cases) |case| {
        const reference_masked = try maskJson(testing.allocator, reference, case.mode);
        defer testing.allocator.free(reference_masked);
        const solver_masked = try maskJson(testing.allocator, case.solver, case.mode);
        defer testing.allocator.free(solver_masked);
        try testing.expectEqual(case.agrees, std.mem.eql(u8, reference_masked, solver_masked));
    }
}

test "text comparison accepts Windows statistics but rejects result and layout changes" {
    const reference = "Board: 16x16, 40 mines\r\nStatus: optimal\r\nOptimal clicks: 43\r\nBreakdown: 12 flags + 12 chords + 6 chains + 13 remaining 3BV\r\nPeak states: 56\r\nSolve time: 0.0009027 seconds\r\n";
    const cases = [_]struct { solver: []const u8, agrees: bool }{
        .{ .solver = "Board: 16x16, 40 mines\nStatus: optimal\nOptimal clicks: 43\nBreakdown: 12 flags + 11 chords + 7 chains + 13 remaining 3BV\nPeak states: 143\nSolve time: 0.000653 seconds\n", .agrees = true },
        .{ .solver = "Board: 16x16, 40 mines\nStatus: optimal\nOptimal clicks: 44\nBreakdown: 12 flags + 12 chords + 6 chains + 14 remaining 3BV\nPeak states: 143\nSolve time: 0.000653 seconds\n", .agrees = false },
        .{ .solver = "Board: 16x16, 40 mines\nStatus: optimal\nOptimal clicks: 43\nBreakdown: 12 flags + 11 chords + 7 chains + 13 remaining 3BV\nSolve time: 0.000653 seconds\n", .agrees = false },
    };
    const reference_masked = try maskText(testing.allocator, reference);
    defer testing.allocator.free(reference_masked);
    for (cases) |case| {
        const solver_masked = try maskText(testing.allocator, case.solver);
        defer testing.allocator.free(solver_masked);
        try testing.expectEqual(case.agrees, std.mem.eql(u8, reference_masked, solver_masked));
    }
}
