const std = @import("std");
pub const log_level: std.log.Level = .debug;
pub const buddy = @import("buddy.zig");
pub const slab = @import("slab.zig");
pub const bump = @import("bump.zig");
test "Buddy test" {
    const alloc = std.heap.page_allocator;
    const base = @intFromPtr((try alloc.alloc(u8, 0x1000 * 1024)).ptr);
    var ba = bump.BumpCtx.setup(base, base + 0x1000 * 1024);
    const ctx = try buddy.BuddyContext.setup(&ba, 0x322a2000, 0x1000);
    const a1 = try ctx.alloc(1);
    std.log.warn("res: {any}\n\n{any}\n", .{ ctx.bmp[0][0..8], ctx.bmp[1][0..8] });
    std.log.warn("\nALLOCATION 1: {x}:{x}\n", .{ a1, a1 + 0x1000 });
    ctx.free(a1);
    std.log.warn("res: {any}\n\n{any}\n", .{ ctx.bmp[0][0..8], ctx.bmp[1][0..8] });
    const a2 = try ctx.alloc(128);
    std.log.warn("\nALLOCATION 2: {x}:{x}\n", .{ a2, a2 + 0x1000 * 128 });
}
const SomeRandomStruct = struct {
    f1: u32 = 9193202,
    f2: usize = 10290123221,
    f3: usize = 102930102,
};

fn alloc_fn(pageno: usize) ?usize {
    const alloc = std.heap.page_allocator;
    return @intFromPtr((alloc.alloc(u8, pageno * 0x1000) catch return null).ptr);
}
fn free_fn(addr: usize, pageno: usize) void {
    const alloc = std.heap.page_allocator;
    alloc.free(@as([*]u8, @ptrFromInt(addr))[0 .. pageno * 0x1000]);
}
test "Slab Test" {
    const alloc = std.heap.smp_allocator;
    const ctx = try slab.Cache.new_cache(2, 8, @sizeOf(SomeRandomStruct), alloc_fn, free_fn, alloc, SomeRandomStruct{});
    const c: *SomeRandomStruct = @ptrCast(@alignCast(try ctx.alloc()));
    std.log.warn("allocation: {*}, {any}, expected: {any}\n", .{ c, c, SomeRandomStruct{} });
    ctx.free(c);
}
