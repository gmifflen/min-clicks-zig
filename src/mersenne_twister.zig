const std = @import("std");

pub const Mt19937 = MersenneTwister(.{
    .Word = u32,
    .n = 624,
    .m = 397,
    .r = 31,
    .a = 0x9908b0df,
    .u = 11,
    .d = 0xffffffff,
    .s = 7,
    .b = 0x9d2c5680,
    .t = 15,
    .c = 0xefc60000,
    .l = 18,
    .f = 1812433253,
});

pub const Mt19937_64 = MersenneTwister(.{
    .Word = u64,
    .n = 312,
    .m = 156,
    .r = 31,
    .a = 0xb5026f5aa96619e9,
    .u = 29,
    .d = 0x5555555555555555,
    .s = 17,
    .b = 0x71d67fffeda60000,
    .t = 37,
    .c = 0xfff7eee000000000,
    .l = 43,
    .f = 6364136223846793005,
});

const Parameters = struct {
    Word: type,
    n: usize,
    m: usize,
    r: comptime_int,
    a: comptime_int,
    u: comptime_int,
    d: comptime_int,
    s: comptime_int,
    b: comptime_int,
    t: comptime_int,
    c: comptime_int,
    l: comptime_int,
    f: comptime_int,
};

fn MersenneTwister(comptime p: Parameters) type {
    return struct {
        const Self = @This();
        pub const Word = p.Word;
        const bits = @bitSizeOf(Word);
        const lower_mask: Word = (@as(Word, 1) << p.r) - 1;
        const upper_mask: Word = ~lower_mask;

        state: [p.n]Word,
        index: usize,

        pub fn init(seed: Word) Self {
            var self: Self = .{ .state = undefined, .index = p.n };
            self.state[0] = seed;
            for (1..p.n) |i| {
                const previous = self.state[i - 1];
                self.state[i] = p.f *% (previous ^ (previous >> (bits - 2))) +% @as(Word, @intCast(i));
            }
            return self;
        }

        pub fn next(self: *Self) Word {
            if (self.index >= p.n) self.twist();
            var y = self.state[self.index];
            self.index += 1;
            y ^= (y >> p.u) & p.d;
            y ^= (y << p.s) & p.b;
            y ^= (y << p.t) & p.c;
            return y ^ (y >> p.l);
        }

        fn twist(self: *Self) void {
            for (0..p.n) |i| {
                const y = (self.state[i] & upper_mask) | (self.state[(i + 1) % p.n] & lower_mask);
                const odd_term: Word = if (y & 1 != 0) p.a else 0;
                self.state[i] = self.state[(i + p.m) % p.n] ^ (y >> 1) ^ odd_term;
            }
            self.index = 0;
        }
    };
}
