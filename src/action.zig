const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Action = struct {
    kind: Kind,
    /// Row-major cell index
    cell: u32,

    pub const Kind = enum(u8) {
        flag = 'F',
        open = 'O',
        chord = 'C',
    };
};

pub const HeuristicResult = struct {
    clicks: u32,
    actions: []const Action = &.{},
};

pub const Recording = enum { with_actions, count_only };

pub const ActionLog = struct {
    arena: Allocator,
    recording: Recording,
    clicks: u32 = 0,
    actions: std.ArrayList(Action) = .empty,

    pub fn add(log: *ActionLog, kind: Action.Kind, cell: u32) Allocator.Error!void {
        log.clicks += 1;
        if (log.recording == .with_actions) try log.actions.append(log.arena, .{ .kind = kind, .cell = cell });
    }

    pub fn result(log: *const ActionLog) HeuristicResult {
        return .{ .clicks = log.clicks, .actions = log.actions.items };
    }
};
