//! Turns an optimal chord selection into a concrete click sequence whose length equals the selection's cost
const std = @import("std");
const Allocator = std.mem.Allocator;
const Board = @import("../board.zig").Board;
const action = @import("../action.zig");
const Action = action.Action;
const ActionLog = action.ActionLog;
const model_module = @import("model.zig");
const Model = model_module.Model;
const Selection = model_module.Selection;

/// Flags first, then each chord chain is started from a zero island when it contains one
/// (an island opening is a seed the board pays for anyway),
/// then from a chosen chord. leftover safe cells are opened directly
pub fn witness(arena: Allocator, m: *const Model, chosen: Selection) Allocator.Error![]const Action {
    const b = m.board;
    var play: Playthrough = .{
        .board = b,
        .selected = try arena.alloc(bool, b.cellCount()),
        .open = try arena.alloc(bool, b.cellCount()),
        .chorded = try arena.alloc(bool, b.cellCount()),
        .log = .{ .arena = arena, .recording = .with_actions },
    };
    @memset(play.selected, false);
    @memset(play.open, false);
    @memset(play.chorded, false);
    for (m.cells, 0..) |cell, i| play.selected[cell] = chosen.isSet(@intCast(i));
    try play.flagAroundSelected(arena);
    for (b.zeros) |island| {
        if (!play.open[island[0]]) try play.seedChain(island[0]);
    }
    for (0..b.cellCount()) |p| {
        if (play.selected[p] and !play.chorded[p]) try play.seedChain(@intCast(p));
    }
    for (0..b.cellCount()) |p| {
        if (b.mine[p] or play.open[p]) continue;
        try play.log.add(.open, @intCast(p));
        play.reveal(@intCast(p));
    }
    return play.log.actions.items;
}

const Playthrough = struct {
    board: *const Board,
    selected: []bool,
    open: []bool,
    chorded: []bool,
    log: ActionLog,

    fn flagAroundSelected(play: *Playthrough, arena: Allocator) Allocator.Error!void {
        const b = play.board;
        const flagged = try arena.alloc(bool, b.cellCount());
        @memset(flagged, false);
        for (play.selected, 0..) |is_selected, p| {
            if (!is_selected) continue;
            for (b.neighbors[p].slice()) |q| flagged[q] = flagged[q] or b.mine[q];
        }
        for (flagged, 0..) |is_flagged, p| {
            if (is_flagged) try play.log.add(.flag, @intCast(p));
        }
    }

    fn seedChain(play: *Playthrough, p: u32) Allocator.Error!void {
        try play.log.add(.open, p);
        play.reveal(p);
        try play.chordUntilStable();
    }

    /// Chords every selected open cell, repeating while chords open more.
    fn chordUntilStable(play: *Playthrough) Allocator.Error!void {
        const b = play.board;
        var changed = true;
        while (changed) {
            changed = false;
            for (0..b.cellCount()) |i| {
                const p: u32 = @intCast(i);
                if (!play.selected[p] or !play.open[p] or play.chorded[p]) continue;
                try play.log.add(.chord, p);
                play.chorded[p] = true;
                changed = true;
                for (b.neighbors[p].slice()) |q| {
                    if (!b.mine[q]) play.reveal(q);
                }
            }
        }
    }

    fn reveal(play: *Playthrough, p: u32) void {
        const b = play.board;
        if (b.mine[p]) @panic("Witness opens a mine");
        play.open[p] = true;
        const z = b.island[p] orelse return;
        for (b.zeros[z]) |q| play.open[q] = true;
        for (b.borders[z]) |q| play.open[q] = true;
    }
};
