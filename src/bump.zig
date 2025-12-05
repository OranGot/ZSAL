//!Simple modular bump allocator made for allocating allocators

const std = @import("std");
pub const BumpCtx = struct {
    cpr: usize,
    max: usize,
    pub inline fn setup(base: usize, high: usize) BumpCtx {
        return BumpCtx{ .cpr = base, .max = high };
    }
    pub fn alloc(self: *BumpCtx, size: usize) !usize {
        if (size == 0) return error.MustBeNonZero;
        const addr = std.mem.alignForward(usize, self.cpr, @as(usize, @intCast(1)) << std.math.log2_int(usize, size));
        const aligned_end = addr + size;
        if (aligned_end > self.max) return error.BumpOutOfMemory;
        self.cpr = addr + size;
        return addr;
    }
};
