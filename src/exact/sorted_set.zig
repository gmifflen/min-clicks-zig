//! Operations on ascending, duplicate-free u32 slices
const std = @import("std");

pub fn normalize(list: *std.ArrayList(u32)) void {
    std.mem.sortUnstable(u32, list.items, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (list.items) |value| {
        if (kept > 0 and list.items[kept - 1] == value) continue;
        list.items[kept] = value;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}

pub fn isSubset(a: []const u32, b: []const u32) bool {
    var j: usize = 0;
    for (a) |value| {
        while (j < b.len and b[j] < value) j += 1;
        if (j == b.len or b[j] != value) return false;
        j += 1;
    }
    return true;
}

pub fn contains(set: []const u32, value: u32) bool {
    return std.sort.binarySearch(u32, set, value, order) != null;
}

fn order(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}
