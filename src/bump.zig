//!Simple modular bump allocator made for allocating allocators

const std = @import("std");
pub const BumpCtx = struct {
    ///ret addr not supported, frees, remaps and resizes are noops
    const interface = std.mem.Allocator.VTable{ .alloc = &mem_alloc, .free = @ptrCast(&noop), .remap = @ptrCast(&noop), .resize = @ptrCast(&noop) };
    cpr: usize,
    max: usize,
    fn noop() void {}
    fn mem_alloc(selfptr: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *BumpCtx = @ptrCast(@alignCast(selfptr));
        const a = self.alloc(len) catch return null;
        return @ptrFromInt(a);
    }
    pub inline fn allocator(ctx: *BumpCtx) std.mem.Allocator {
        return std.mem.Allocator{ .ptr = @ptrCast(ctx), .vtable = &interface };
    }
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
