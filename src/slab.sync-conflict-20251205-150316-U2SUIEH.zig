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
    slab_list: std.ArrayList(Slab),
    alloc_fn: *fn (pageno: usize) ?usize,
    free_fn: *fn (addr: usize) ?usize,
    small_alloc: std.mem.Allocator,
    default_val: [*]u8,
    ///no_slabs -- how many more slabs to add
    pub fn extend_cache(self: *Cache, no_slabs: usize) !void {
        for (0..no_slabs) |_| {
            const start = self.alloc_fn(self.pages_per_slab) orelse return error.AllocFail;
            try self.slab_list.append(self.small_alloc, Slab{ .allocs_done = 0, .frees_done = 0, .start = start });
        }
    }
    ///initialises the last slab in the array list strucuture
    inline fn pre_init_slab(self: *Cache) void {
        var c_ptr = self.slab_list.getLast().start;
        const high = c_ptr + PAGE_SIZE * self.pages_per_slab;
        while (c_ptr < high) : (c_ptr += self.size_full) {
            @memcpy(@as([*]u8, @ptrFromInt(c_ptr))[0..self.obj_size], self.default_val[0..self.obj_size]);
            const md_ptr = @as(*ObjectMd, @ptrFromInt(c_ptr + self.obj_size));
            md_ptr = .{ .used = false };
        }
    }
    pub fn alloc(self: *Cache) *anyopaque {
        for (&self.slab_list.items) |*e| {
            if (e.allocs_done - e.frees_done != 0 and e.allocs_done - e.frees_done != (self.pages_per_slab * PAGE_SIZE) / self.size_full) {
                var ptr = e.start + self.obj_size;
                const high = ptr + PAGE_SIZE * self.pages_per_slab;
                while (ptr < high) : (ptr += self.size_full) {
                    const md_ptr = @as(*ObjectMd, @ptrFromInt(ptr));
                    if (md_ptr.used == false) {
                        e.allocs_done += 1;
                        md_ptr.used = true;
                        return @ptrFromInt(ptr - self.obj_size);
                    }
                }
            }
        }
    }
    pub fn new_cache(
        pre_init_slabs_no: usize,
        pages_per_slab: usize,
        obj_size: usize,
        alloc_fn: *fn (pageno: usize) ?usize,
        free_fn: *fn (pageno: usize) ?usize,
        small_alloc: std.mem.Allocator,
        pre_init_value: [*]u8,
    ) !*Cache {
        const self: *Cache = try small_alloc.create(Cache);
        self = .{
            .alloc_fn = alloc_fn,
            .obj_size = obj_size,
            .small_allocator = small_alloc,
            .pages_per_slab = pages_per_slab,
            .size_full = obj_size + @sizeOf(ObjectMd),
            .free_fn = free_fn,
            .default_val = pre_init_value,
        };
        errdefer {
            for (self.slab_list.items) |i| {
                self.free_fn(i.start);
            }
            self.slab_list.deinit(small_alloc);
            small_alloc.destroy(self);
        }
        self.extend_cache(pre_init_slabs_no);
    }
};
