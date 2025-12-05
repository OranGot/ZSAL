//!Slab allocator
const std = @import("std");
pub const Slab = struct { start: usize, frees_done: u32, allocs_done: u32 };
///Object metadata is kept in memory right after the data
pub const ObjectMd = extern struct {
    used: bool,
};
const PAGE_SIZE = 0x1000;
pub const State = enum { Full, Partial, Free };
pub const Cache = struct {
    obj_size: usize,
    size_full: usize,
    pages_per_slab: usize,
    empty_slab_list: std.ArrayList(*Slab),
    full_slab_list: std.ArrayList(*Slab),
    partial_slab_list: std.ArrayList(*Slab),
    alloc_fn: *const fn (pageno: usize) ?usize,
    free_fn: *const fn (addr: usize, pageno: usize) void,
    small_alloc: std.mem.Allocator,
    default_val: [*]u8,
    ///no_slabs -- how many more slabs to add
    pub fn extend_cache(self: *Cache, no_slabs: usize) !void {
        for (0..no_slabs) |_| {
            const start = self.alloc_fn(self.pages_per_slab) orelse return error.AllocFail;
            const ns = try self.small_alloc.create(Slab);
            ns.* = Slab{ .allocs_done = 0, .frees_done = 0, .start = start };
            try self.empty_slab_list.append(self.small_alloc, ns);
            self.pre_init_slab();
        }
    }
    ///initialises the last slab in the array list strucuture
    inline fn pre_init_slab(self: *Cache) void {
        var c_ptr = self.empty_slab_list.getLast().start;
        const high = c_ptr + PAGE_SIZE * self.pages_per_slab;
        // std.log.warn("c_ptr = {x}, high = {x}, size full = {x}\n", .{ c_ptr, high, self.size_full });
        while (c_ptr < high) : (c_ptr += self.size_full) {
            @memcpy(@as([*]u8, @ptrFromInt(c_ptr))[0..self.obj_size], self.default_val[0..self.obj_size]);
            const md_ptr = @as(*ObjectMd, @ptrFromInt(c_ptr + self.obj_size));
            md_ptr.* = .{ .used = false };
        }
    }
    pub fn free(self: *Cache, addr: *anyopaque) void {
        for (self.full_slab_list.items, 0..self.full_slab_list.items.len) |e, i| {
            if (e.start <= @intFromPtr(addr) and @intFromPtr(addr) < e.start + self.pages_per_slab * PAGE_SIZE) {
                const md_ptr = @as(*ObjectMd, @ptrFromInt(@intFromPtr(addr) + self.obj_size));
                if (md_ptr.used == false) {
                    std.log.warn("Pointer already freed. Metadata at: {*}\n", .{md_ptr});
                } else md_ptr.used = false;
                e.frees_done += 1;
                const item = self.full_slab_list.swapRemove(i);
                self.partial_slab_list.append(self.small_alloc, item) catch return;

                return;
            }
        }
        for (self.full_slab_list.items, 0..self.full_slab_list.items.len) |e, i| {
            if (e.start <= @intFromPtr(addr) and @intFromPtr(addr) < e.start + self.pages_per_slab * PAGE_SIZE) {
                const md_ptr = @as(*ObjectMd, @ptrFromInt(@intFromPtr(addr) + self.obj_size));
                if (md_ptr.used == false) {
                    std.log.warn("Pointer already freed. Metadata at: {*}\n", .{md_ptr});
                } else md_ptr.used = false;
                e.frees_done += 1;
                if (e.allocs_done - e.frees_done == 0) {
                    const item = self.full_slab_list.swapRemove(i);
                    self.empty_slab_list.append(self.small_alloc, item) catch return;
                }
                return;
            }
        }
    }
    pub fn alloc(self: *Cache) !*anyopaque {
        if (self.partial_slab_list.items.len == 0) {
            var val = self.empty_slab_list.pop() orelse return error.PopFailed;
            val.allocs_done += 1;

            const md_ptr = @as(*ObjectMd, @ptrFromInt(val.start + self.obj_size));
            md_ptr.used = true;
            try self.partial_slab_list.append(self.small_alloc, val);
            return @ptrFromInt(val.start);
        } else {
            const cws = self.partial_slab_list.getLast(); //working from back of the list as it will be much easier to remove elements
            var ptr = cws.start;
            const high = ptr + PAGE_SIZE * self.pages_per_slab;
            while (ptr < high) : (ptr += self.size_full) {
                const md_ptr = @as(*ObjectMd, @ptrFromInt(cws.start + self.obj_size));
                if (md_ptr.used == false) {
                    md_ptr.used = true;
                    cws.allocs_done += 1;
                    if (cws.allocs_done - cws.frees_done >= (self.pages_per_slab * PAGE_SIZE) / self.size_full) {
                        _ = self.partial_slab_list.pop() orelse return error.PopFail;
                        try self.full_slab_list.append(self.small_alloc, cws);
                    }
                    return @ptrFromInt(ptr);
                }
            }
        }
        try self.extend_cache(1);
        return self.alloc();
    }
    pub fn new_cache(
        pre_init_slabs_no: usize,
        pages_per_slab: usize,
        obj_size: usize,
        alloc_fn: *const fn (pageno: usize) ?usize,
        free_fn: *const fn (addr: usize, pageno: usize) void,
        small_alloc: std.mem.Allocator,
        pre_init_value: anytype,
    ) !*Cache {
        const self: *Cache = try small_alloc.create(Cache);
        const val = @as([*]u8, @ptrCast(try small_alloc.create(@TypeOf(pre_init_value))));
        @memcpy(val[0..@sizeOf(@TypeOf(pre_init_value))], @as([*]u8, @ptrCast(@constCast(&pre_init_value))));
        var full_size = @as(usize, @intCast(1)) << @truncate(std.math.log2_int_ceil(usize, obj_size));
        if (full_size == obj_size)
            full_size = @as(usize, @intCast(2)) << @truncate(std.math.log2_int_ceil(usize, obj_size));
        if (full_size <= obj_size) {
            return error.IncorrectAlignement;
        }
        self.* = .{
            .alloc_fn = alloc_fn,
            .obj_size = obj_size,
            .small_alloc = small_alloc,
            .pages_per_slab = pages_per_slab,
            .size_full = full_size,
            .free_fn = free_fn,
            .default_val = @ptrCast(val),
            .empty_slab_list = std.ArrayList(*Slab).empty,
            .full_slab_list = std.ArrayList(*Slab).empty,
            .partial_slab_list = std.ArrayList(*Slab).empty,
        };
        errdefer {
            for (self.empty_slab_list.items) |i| {
                self.free_fn(i.start, pages_per_slab);
            }

            self.empty_slab_list.deinit(small_alloc);
            small_alloc.destroy(self);
        }
        try self.extend_cache(pre_init_slabs_no);
        return self;
    }
};
