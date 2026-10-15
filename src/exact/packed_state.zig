//! Compact DP states for boundaries that fit three 64-bit words,
//! and the layer table that deduplicates and prunes them
const std = @import("std");
const Allocator = std.mem.Allocator;
const schedule_module = @import("schedule.zig");
const Step = schedule_module.Step;
const WeightedMask = schedule_module.WeightedMask;

pub const max_connections = 24;
pub const max_expanded_connections = 31;
pub const max_factors = 64;

pub const PackedKey = struct {
    lo: u64 = 0,
    hi: u64 = 0,
    factors: u64 = 0,

    pub fn labels(k: PackedKey) [24]u8 {
        var out: [24]u8 = undefined;
        for (out[0..12], out[12..], 0..) |*low, *high, i| {
            low.* = @as(u5, @truncate(k.lo >> @intCast(5 * i)));
            high.* = @as(u5, @truncate(k.hi >> @intCast(5 * i)));
        }
        return out;
    }

    pub fn put(k: *PackedKey, i: usize, value: u5) void {
        const shifted = @as(u64, value) << @intCast(5 * (i % 12));
        if (i < 12) k.lo |= shifted else k.hi |= shifted;
    }
};

fn mix(input: u64) u64 {
    var x = input;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn overLoaded(entries: usize, buckets: usize) bool {
    return entries * 4 > buckets * 3;
}

fn bit32(i: usize) u32 {
    return @as(u32, 1) << @intCast(i);
}

pub const ConnectionResult = struct {
    lo: u64 = 0,
    hi: u64 = 0,
    seeds: u8 = 0,
    live: bool = false,
};

pub fn connectionTransitions(key: PackedKey, st: *const Step) [2]ConnectionResult {
    const old = st.before.len;
    const count = st.expanded.len;
    var original: [32]u8 = @splat(0);
    original[0..24].* = key.labels();
    var highest: u8 = 0;
    for (original[0..old]) |l| highest = @max(highest, l);
    for (old..count - 1) |j| {
        highest += 1;
        original[j] = highest;
    }
    return .{ transition(original, highest, false, st), transition(original, highest, true, st) };
}

fn transition(original: [32]u8, highest: u8, take: bool, st: *const Step) ConnectionResult {
    const count = st.expanded.len;
    var labels = original;
    if (take) joinSelected(&labels, highest + 1, st);
    var present: u32 = 0;
    for (labels[0..count]) |l| present |= bit32(l);
    var surviving: u32 = 0;
    for (st.keep) |j| surviving |= bit32(labels[j]);
    const out = reduceToContacts(canonicalSurvivors(labels, st), st);
    return .{
        .lo = out.lo,
        .hi = out.hi,
        .seeds = @popCount(present & ~surviving & ~@as(u32, 1)),
        .live = surviving & ~@as(u32, 1) != 0,
    };
}

fn joinSelected(labels: *[32]u8, component: u8, st: *const Step) void {
    const count = st.expanded.len;
    labels[count - 1] = component;
    var merged: u32 = 0;
    for (st.neighbors) |j| merged |= bit32(labels[j]);
    merged &= ~@as(u32, 1);
    for (labels[0 .. count - 1]) |*l| {
        if (merged & bit32(l.*) != 0) l.* = component;
    }
}

fn canonicalSurvivors(labels: [32]u8, st: *const Step) [24]u8 {
    var out: [24]u8 = @splat(0);
    var rename: [32]u8 = @splat(0);
    var fresh: u8 = 0;
    for (st.keep, out[0..st.keep.len]) |source, *slot| {
        const l = labels[source];
        if (l != 0 and rename[l] == 0) {
            fresh += 1;
            rename[l] = fresh;
        }
        slot.* = rename[l];
    }
    return out;
}

fn reduceToContacts(canonical: [24]u8, st: *const Step) PackedKey {
    var labels = canonical;
    var components: ComponentMembers = .init(labels[0..st.keep.len]);
    components.absorbCoveredPositions(&labels, st);
    components.dropRedundantMembers(labels, st);
    return components.pack(labels, st.keep.len);
}

const ComponentMembers = struct {
    members: [32]u32 = @splat(0),
    labels_used: u5 = 0,

    fn init(labels: []const u8) ComponentMembers {
        var c: ComponentMembers = .{};
        for (labels, 0..) |l, j| {
            if (l == 0) continue;
            c.members[l] |= bit32(j);
            c.labels_used = @max(c.labels_used, @as(u5, @intCast(l)));
        }
        return c;
    }

    fn absorbCoveredPositions(c: *ComponentMembers, labels: *[24]u8, st: *const Step) void {
        for (labels[0..st.keep.len], 0..) |*l, j| {
            if (l.* != 0) continue;
            const covering = firstCoveringLabel(c.members, c.labels_used, st.contacts[j]) orelse continue;
            l.* = covering;
            c.members[covering] |= bit32(j);
        }
    }

    fn dropRedundantMembers(c: *ComponentMembers, labels: [24]u8, st: *const Step) void {
        var j = st.keep.len;
        while (j > 0) {
            j -= 1;
            const l = labels[j];
            if (l == 0) continue;
            const others = c.members[l] & ~bit32(j);
            if (others != 0 and coversAll(others, st.contacts[j])) c.members[l] = others;
        }
    }

    fn pack(c: *const ComponentMembers, labels: [24]u8, size: usize) PackedKey {
        var reduced: PackedKey = .{};
        var rename: [32]u5 = @splat(0);
        var fresh: u5 = 0;
        for (labels[0..size], 0..) |l, i| {
            if (c.members[l] & bit32(i) == 0) continue;
            if (rename[l] == 0) {
                fresh += 1;
                rename[l] = fresh;
            }
            reduced.put(i, rename[l]);
        }
        return reduced;
    }
};

fn firstCoveringLabel(members: [32]u32, labels_used: u5, contacts: []const u32) ?u5 {
    var l: u5 = 1;
    while (l <= labels_used) : (l += 1) {
        if (coversAll(members[l], contacts)) return l;
        if (l == 31) break;
    }
    return null;
}

fn coversAll(set: u32, contacts: []const u32) bool {
    for (contacts) |contact| {
        if (set & contact == 0) return false;
    }
    return true;
}

fn contactClosure(members: u32, st: *const Step) u32 {
    var closure = members;
    for (st.contacts, 0..) |contacts, v| {
        if (members & bit32(v) != 0) continue;
        if (coversAll(members, contacts)) closure |= bit32(v);
    }
    return closure;
}

pub const ContactPartition = struct {
    components: [24]u64 = @splat(0),
    count: u8 = 0,
    united: u64 = 0,

    pub fn init(key: PackedKey, st: *const Step) ContactPartition {
        var p: ContactPartition = .{};
        if (st.future_signatures) |signatures| p.fillFromSignatures(key, signatures) else p.fillFromClosures(key, st);
        std.mem.sortUnstable(u64, p.components[0..p.count], {}, std.sort.asc(u64));
        return p;
    }

    fn fillFromSignatures(p: *ContactPartition, key: PackedKey, signatures: []const u64) void {
        var by_label: [32]u64 = @splat(0);
        var present: u32 = 0;
        const labels = key.labels();
        for (signatures, 0..) |signature, v| {
            const l = labels[v];
            if (l == 0) continue;
            present |= bit32(l);
            by_label[l] |= signature;
        }
        var remaining = present;
        while (remaining != 0) : (remaining &= remaining - 1) {
            const signature = by_label[@ctz(remaining)];
            p.united |= signature;
            p.components[p.count] = signature;
            p.count += 1;
        }
    }

    fn fillFromClosures(p: *ContactPartition, key: PackedKey, st: *const Step) void {
        var members: [32]u32 = @splat(0);
        var all: u32 = 0;
        const labels = key.labels();
        for (0..st.contacts.len) |v| {
            const l = labels[v];
            if (l == 0) continue;
            members[l] |= bit32(v);
            all |= members[l];
        }
        p.united = contactClosure(all, st);
        for (members) |mask| {
            if (mask == 0) continue;
            p.components[p.count] = contactClosure(mask, st);
            p.count += 1;
        }
    }
};

fn contactCoarsens(coarse: *const ContactPartition, fine: *const ContactPartition) bool {
    if (coarse.united != fine.united or coarse.count > fine.count) return false;
    if (coarse.count == 0) return fine.count == 0;
    if (coarse.count == 1) return true;
    var eligible: [24]u32 = @splat(0);
    var covered: u32 = 0;
    for (0..coarse.count) |c| {
        for (0..fine.count) |f| {
            if (fine.components[f] & ~coarse.components[c] != 0) continue;
            eligible[c] |= bit32(f);
            covered |= bit32(f);
        }
    }
    if (covered != bit32(fine.count) - 1) return false;
    var matching: AnchorMatching = .{ .eligible = eligible[0..coarse.count] };
    for (0..coarse.count) |c| {
        var seen: u32 = 0;
        if (!matching.augment(@intCast(c), &seen)) return false;
    }
    return true;
}

const AnchorMatching = struct {
    eligible: []const u32,
    owner: [24]i8 = @splat(-1),

    fn augment(m: *AnchorMatching, c: u8, seen: *u32) bool {
        var available = m.eligible[c] & ~seen.*;
        while (available != 0) : (available &= available - 1) {
            const f = @ctz(available);
            seen.* |= bit32(f);
            if (m.owner[f] < 0 or m.augment(@intCast(m.owner[f]), seen)) {
                m.owner[f] = @intCast(c);
                return true;
            }
        }
        return false;
    }
};

pub const ConnectionPool = struct {
    keys: std.ArrayList(Key) = .empty,
    buckets: []u32 = &.{},

    const Key = struct { lo: u64, hi: u64 };

    fn hash(lo: u64, hi: u64) u64 {
        return mix(lo ^ std.math.rotl(u64, hi, 27));
    }

    pub fn deinit(pool: *ConnectionPool, gpa: Allocator) void {
        pool.keys.deinit(gpa);
        gpa.free(pool.buckets);
    }

    pub fn clear(pool: *ConnectionPool) void {
        pool.keys.clearRetainingCapacity();
        @memset(pool.buckets, 0);
    }

    pub fn intern(pool: *ConnectionPool, gpa: Allocator, lo: u64, hi: u64) Allocator.Error!u32 {
        if (pool.buckets.len == 0) try pool.rehash(gpa, 16);
        var slot = pool.slotFor(lo, hi);
        if (pool.buckets[slot] != 0) return pool.buckets[slot] - 1;
        if (overLoaded(pool.keys.items.len + 1, pool.buckets.len)) {
            try pool.rehash(gpa, pool.buckets.len * 2);
            slot = pool.slotFor(lo, hi);
        }
        const id: u32 = @intCast(pool.keys.items.len);
        try pool.keys.append(gpa, .{ .lo = lo, .hi = hi });
        pool.buckets[slot] = id + 1;
        return id;
    }

    fn slotFor(pool: *const ConnectionPool, lo: u64, hi: u64) usize {
        const mask = pool.buckets.len - 1;
        var slot: usize = @intCast(hash(lo, hi) & mask);
        while (pool.buckets[slot] != 0) : (slot = (slot + 1) & mask) {
            const key = pool.keys.items[pool.buckets[slot] - 1];
            if (key.lo == lo and key.hi == hi) return slot;
        }
        return slot;
    }

    pub fn unpack(pool: *const ConnectionPool, id: u32) PackedKey {
        const key = pool.keys.items[id];
        return .{ .lo = key.lo, .hi = key.hi };
    }

    fn rehash(pool: *ConnectionPool, gpa: Allocator, size: usize) Allocator.Error!void {
        const buckets = try gpa.alloc(u32, size);
        @memset(buckets, 0);
        for (pool.keys.items, 0..) |key, i| {
            var slot: usize = @intCast(hash(key.lo, key.hi) & (size - 1));
            while (buckets[slot] != 0) slot = (slot + 1) & (size - 1);
            buckets[slot] = @intCast(i + 1);
        }
        gpa.free(pool.buckets);
        pool.buckets = buckets;
    }
};

pub const PruneOutcome = struct {
    removed: usize,
    cross: ?CrossWork = null,
};

pub const CrossWork = struct { work: usize, removed: usize };

pub const FlatTable = struct {
    connections: ConnectionPool = .{},
    nodes: std.ArrayList(Node) = .empty,
    choices: std.ArrayList(u64) = .empty,
    origins: std.ArrayList(Origin) = .empty,
    buckets: []u32 = &.{},
    words: usize,

    pub const Origin = struct { parent: u32, take: ?u32 };

    pub const Node = struct {
        factors: u64,
        connection: u32,
        cost: i32,
    };

    comptime {
        if (@sizeOf(Node) != 16) @compileError("FlatTable.Node must stay 16 bytes");
    }

    pub fn deinit(table: *FlatTable, gpa: Allocator) void {
        table.connections.deinit(gpa);
        table.nodes.deinit(gpa);
        table.choices.deinit(gpa);
        table.origins.deinit(gpa);
        gpa.free(table.buckets);
    }

    pub fn clear(table: *FlatTable) void {
        table.nodes.clearRetainingCapacity();
        table.choices.clearRetainingCapacity();
        table.origins.clearRetainingCapacity();
        table.connections.clear();
        @memset(table.buckets, 0);
    }

    pub fn choicesOf(table: *const FlatTable, index: usize) []const u64 {
        return table.choices.items[index * table.words ..][0..table.words];
    }

    fn hash(connection: u32, factors: u64) u64 {
        return mix(factors ^ (@as(u64, connection) *% 0x9e3779b97f4a7c15));
    }

    pub fn insertRoot(table: *FlatTable, gpa: Allocator, connection: u32, factors: u64, cost: i32) Allocator.Error!void {
        if (table.nodes.items.len != 0) @panic("The root state must be a layer's only state");
        _ = try table.claim(gpa, connection, factors, cost);
        try table.choices.appendNTimes(gpa, 0, table.words);
    }

    pub fn insert(table: *FlatTable, gpa: Allocator, connection: u32, factors: u64, cost: i32, origin: Origin) Allocator.Error!void {
        const index = try table.claim(gpa, connection, factors, cost) orelse return;
        table.origins.items[index] = origin;
    }

    pub fn materialize(table: *FlatTable, gpa: Allocator, previous: *const FlatTable) Allocator.Error!void {
        try table.choices.resize(gpa, table.nodes.items.len * table.words);
        for (table.origins.items, 0..) |origin, i| {
            writeChoices(table.choices.items[i * table.words ..][0..table.words], previous.choicesOf(origin.parent), origin.take);
        }
    }

    fn writeChoices(target: []u64, source: []const u64, take: ?u32) void {
        @memcpy(target, source);
        if (take) |v| target[v / 64] |= @as(u64, 1) << @intCast(v % 64);
    }

    fn claim(table: *FlatTable, gpa: Allocator, connection: u32, factors: u64, cost: i32) Allocator.Error!?usize {
        if (table.buckets.len == 0) try table.rehash(gpa, 16);
        const slot = table.slotFor(connection, factors);
        if (table.buckets[slot] == 0) return try table.append(gpa, slot, connection, factors, cost);
        const existing = table.buckets[slot] - 1;
        if (table.nodes.items[existing].cost <= cost) return null;
        table.nodes.items[existing].cost = cost;
        return existing;
    }

    fn slotFor(table: *const FlatTable, connection: u32, factors: u64) usize {
        const mask = table.buckets.len - 1;
        var slot: usize = @intCast(hash(connection, factors) & mask);
        while (table.buckets[slot] != 0) : (slot = (slot + 1) & mask) {
            const node = table.nodes.items[table.buckets[slot] - 1];
            if (node.connection == connection and node.factors == factors) return slot;
        }
        return slot;
    }

    fn append(table: *FlatTable, gpa: Allocator, empty_slot: usize, connection: u32, factors: u64, cost: i32) Allocator.Error!usize {
        var slot = empty_slot;
        if (overLoaded(table.nodes.items.len + 1, table.buckets.len)) {
            try table.rehash(gpa, table.buckets.len * 2);
            slot = table.slotFor(connection, factors);
        }
        try table.nodes.ensureUnusedCapacity(gpa, 1);
        try table.origins.ensureUnusedCapacity(gpa, 1);
        const index = table.nodes.items.len;
        try table.nodes.append(gpa, .{ .factors = factors, .connection = connection, .cost = cost });
        _ = try table.origins.addOne(gpa);
        table.buckets[slot] = @intCast(index + 1);
        return index;
    }

    fn rehash(table: *FlatTable, gpa: Allocator, size: usize) Allocator.Error!void {
        const buckets = try gpa.alloc(u32, size);
        @memset(buckets, 0);
        for (table.nodes.items, 0..) |node, i| {
            var slot: usize = @intCast(hash(node.connection, node.factors) & (size - 1));
            while (buckets[slot] != 0) slot = (slot + 1) & (size - 1);
            buckets[slot] = @intCast(i + 1);
        }
        gpa.free(table.buckets);
        table.buckets = buckets;
    }

    pub fn pruneDominated(table: *FlatTable, scratch: *std.heap.ArenaAllocator, st: *const Step, cross: bool) Allocator.Error!PruneOutcome {
        const cross_threshold = 4;
        const count = table.nodes.items.len;
        const runs_cross = cross and count >= cross_threshold;
        if (count < 2 or (st.live_weights.len == 0 and (st.contacts.len == 0 or !runs_cross))) return .{ .removed = 0 };
        _ = scratch.reset(.retain_capacity);
        const arena = scratch.allocator();
        var pruning: Pruning = .{
            .nodes = table.nodes.items,
            .removed = try arena.alloc(bool, count),
            .extra = try extraWeights(arena, st.live_weights),
        };
        @memset(pruning.removed, false);
        const order = try pruning.groupByConnection(arena, table.connections.keys.items.len);
        try pruning.pruneWithinConnection(arena, order);
        if (runs_cross) try pruning.pruneAcrossPartitions(arena, order, &table.connections, st);
        table.compact(pruning.removed);
        const cross_work: ?CrossWork = if (runs_cross) .{ .work = pruning.cross_work, .removed = pruning.cross_removed } else null;
        return .{ .removed = count - table.nodes.items.len, .cross = cross_work };
    }

    fn compact(table: *FlatTable, removed: []const bool) void {
        var kept: usize = 0;
        for (removed, 0..) |gone, i| {
            if (gone) continue;
            table.nodes.items[kept] = table.nodes.items[i];
            table.origins.items[kept] = table.origins.items[i];
            kept += 1;
        }
        table.nodes.shrinkRetainingCapacity(kept);
        table.origins.shrinkRetainingCapacity(kept);
    }
};

fn extraWeights(arena: Allocator, live: []const WeightedMask) Allocator.Error![]const WeightedMask {
    var extra: std.ArrayList(WeightedMask) = .empty;
    for (live) |entry| {
        if (entry.weight > 1) try extra.append(arena, .{ .mask = entry.mask, .weight = entry.weight - 1 });
    }
    return extra.items;
}

const Pruning = struct {
    nodes: []const FlatTable.Node,
    removed: []bool,
    extra: []const WeightedMask,
    cross_work: usize = 0,
    cross_removed: usize = 0,

    fn loss(p: *const Pruning, source: u32, target: u32) i32 {
        const missing = p.nodes[target].factors & ~p.nodes[source].factors;
        var penalty: i32 = @popCount(missing);
        for (p.extra) |entry| {
            if (missing & entry.mask != 0) penalty += entry.weight;
        }
        return penalty;
    }

    fn cheaper(nodes: []const FlatTable.Node, a: u32, b: u32) bool {
        if (nodes[a].cost != nodes[b].cost) return nodes[a].cost < nodes[b].cost;
        return nodes[a].factors > nodes[b].factors;
    }

    fn groupByConnection(p: *const Pruning, arena: Allocator, connection_count: usize) Allocator.Error![]u32 {
        const offsets = try arena.alloc(usize, connection_count + 1);
        @memset(offsets, 0);
        for (p.nodes) |node| offsets[node.connection + 1] += 1;
        for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
        const cursor = try arena.dupe(usize, offsets);
        const order = try arena.alloc(u32, p.nodes.len);
        for (p.nodes, 0..) |node, i| {
            order[cursor[node.connection]] = @intCast(i);
            cursor[node.connection] += 1;
        }
        for (0..connection_count) |c| std.mem.sortUnstable(u32, order[offsets[c]..offsets[c + 1]], p.nodes, cheaper);
        return order;
    }

    fn pruneWithinConnection(p: *Pruning, arena: Allocator, order: []const u32) Allocator.Error!void {
        var survivors: std.ArrayList(u32) = .empty;
        var last_connection: ?u32 = null;
        for (order) |i| {
            const node = p.nodes[i];
            if (last_connection != node.connection) {
                survivors.clearRetainingCapacity();
                last_connection = node.connection;
            }
            if (p.dominatedBySurvivor(i, survivors.items)) {
                p.removed[i] = true;
            } else {
                try survivors.append(arena, i);
            }
        }
    }

    fn dominatedBySurvivor(p: *const Pruning, i: u32, survivors: []const u32) bool {
        const node = p.nodes[i];
        for (survivors) |j| {
            if (node.factors & ~p.nodes[j].factors == 0) return true;
            if (p.nodes[j].cost == node.cost) continue;
            if (p.nodes[j].cost + p.loss(j, i) <= node.cost) return true;
        }
        return false;
    }

    const Group = struct {
        contacts: ContactPartition,
        begin: usize,
        end: usize,
        cheapest: i32,
        dearest: i32,
        alive: usize,
        population: u32 = 0,
        sizes: [24]u8 = @splat(0),

        fn lessThan(groups: []const Group, ia: u32, ib: u32) bool {
            const a = &groups[ia];
            const b = &groups[ib];
            if (a.contacts.united != b.contacts.united) return a.contacts.united < b.contacts.united;
            if (a.contacts.count != b.contacts.count) return a.contacts.count < b.contacts.count;
            if (a.population != b.population) return a.population > b.population;
            return switch (std.mem.order(u64, a.contacts.components[0..a.contacts.count], b.contacts.components[0..b.contacts.count])) {
                .lt => true,
                .gt => false,
                .eq => a.begin < b.begin,
            };
        }
    };

    fn pruneAcrossPartitions(p: *Pruning, arena: Allocator, order: []const u32, pool: *const ConnectionPool, st: *const Step) Allocator.Error!void {
        const survivors = try p.survivorsByConnection(arena, order, pool, st);
        const groups = survivors.groups;
        p.cross_work += groups.len;
        const ranked = try arena.alloc(u32, groups.len);
        for (ranked, 0..) |*r, i| r.* = @intCast(i);
        std.mem.sortUnstable(u32, ranked, @as([]const Group, groups), Group.lessThan);
        var start: usize = 0;
        while (start < ranked.len) {
            var end = start + 1;
            while (end < ranked.len and groups[ranked[end]].contacts.united == groups[ranked[start]].contacts.united) end += 1;
            for (start + 1..end) |f| p.pruneByCoarserGroups(survivors.order, groups, ranked[start..f], &groups[ranked[f]]);
            start = end;
        }
    }

    const Survivors = struct { order: []const u32, groups: []Group };

    fn survivorsByConnection(p: *const Pruning, arena: Allocator, order: []const u32, pool: *const ConnectionPool, st: *const Step) Allocator.Error!Survivors {
        const survivor_order = try arena.alloc(u32, order.len);
        const groups = try arena.alloc(Group, pool.keys.items.len);
        var survivor_count: usize = 0;
        var group_count: usize = 0;
        var first: usize = 0;
        while (first < order.len) {
            const connection = p.nodes[order[first]].connection;
            var last = first + 1;
            while (last < order.len and p.nodes[order[last]].connection == connection) last += 1;
            const begin = survivor_count;
            for (order[first..last]) |i| {
                if (p.removed[i]) continue;
                survivor_order[survivor_count] = i;
                survivor_count += 1;
            }
            if (survivor_count != begin) {
                groups[group_count] = p.makeGroup(pool.unpack(connection), st, survivor_order[0..survivor_count], begin);
                group_count += 1;
            }
            first = last;
        }
        return .{ .order = survivor_order[0..survivor_count], .groups = groups[0..group_count] };
    }

    fn pruneByCoarserGroups(p: *Pruning, survivors: []const u32, groups: []const Group, coarser: []const u32, fine: *Group) void {
        for (coarser) |c| {
            const coarse = &groups[c];
            if (coarse.contacts.count > fine.contacts.count or fine.alive == 0) return;
            p.cross_work += 1;
            if (coarse.cheapest > fine.dearest) continue;
            if (mayCoarsen(coarse, fine)) p.removeCoveredStates(survivors, coarse, fine);
        }
    }

    fn makeGroup(p: *const Pruning, key: PackedKey, st: *const Step, survivors: []const u32, begin: usize) Group {
        const end = survivors.len;
        var group: Group = .{
            .contacts = ContactPartition.init(key, st),
            .begin = begin,
            .end = end,
            .cheapest = p.nodes[survivors[begin]].cost,
            .dearest = p.nodes[survivors[end - 1]].cost,
            .alive = end - begin,
        };
        for (group.contacts.components[0..group.contacts.count], 0..) |component, c| {
            const size: u8 = @popCount(component);
            group.population += size;
            group.sizes[c] = size;
        }
        std.mem.sortUnstable(u8, group.sizes[0..group.contacts.count], {}, std.sort.asc(u8));
        return group;
    }

    fn mayCoarsen(coarse: *const Group, fine: *const Group) bool {
        const cc = coarse.contacts.count;
        if (cc == fine.contacts.count and std.mem.eql(u64, coarse.contacts.components[0..cc], fine.contacts.components[0..cc])) return true;
        for (0..cc) |k| {
            if (fine.sizes[k] > coarse.sizes[k]) return false;
        }
        if (cc != 0 and fine.sizes[fine.contacts.count - 1] > coarse.sizes[cc - 1]) return false;
        return contactCoarsens(&coarse.contacts, &fine.contacts);
    }

    fn removeCoveredStates(p: *Pruning, survivors: []const u32, coarse: *const Group, fine: *Group) void {
        for (survivors[fine.begin..fine.end]) |target| {
            if (p.removed[target] or !p.coveredBy(survivors[coarse.begin..coarse.end], target)) continue;
            p.removed[target] = true;
            p.cross_removed += 1;
            fine.alive -= 1;
        }
    }

    fn coveredBy(p: *Pruning, sources: []const u32, target: u32) bool {
        for (sources) |source| {
            p.cross_work += 1;
            const allowance = p.nodes[target].cost - p.nodes[source].cost;
            if (allowance < 0) return false;
            if (p.loss(source, target) <= allowance) return true;
        }
        return false;
    }
};
