//!Buddy allocator for physical memory management
const bump = @import("bump.zig");
const std = @import("std");
pub const Restrict = struct {
    len: usize,
    addr: usize,
};
pub const Input = struct {
    pre_reserved_pages_base: usize,
    pre_reserved_pages_high: usize,
    memsize: usize,
    page_size: usize,
};

const BitmapEntry = packed struct(u8) {
    used: bool,
    restricted: bool,
    allocation_origin: bool,
    unused: u5,
};
pub const BuddyContext = struct {
    page_size: usize,
    memsize: usize,
    layers: u16,
    bmp: [][]BitmapEntry,
    ///Pages provided are assumed to be already set to 0
    pub fn setup(
        allocator: *bump.BumpCtx,
        memsize: usize,
        page_size: usize,
    ) !*BuddyContext {
        if (memsize < page_size) return error.MemsizeLessThanAPage;
        const ctx: *BuddyContext = @ptrFromInt(try allocator.alloc(@sizeOf(BuddyContext)));
        const layer_count = @as(u16, @intCast(std.math.log2_int_ceil(usize, (memsize / page_size)) + 1));
        ctx.memsize = memsize;
        ctx.page_size = page_size;
        ctx.layers = layer_count;
        ctx.bmp = @as([*][]BitmapEntry, @ptrFromInt(try allocator.alloc(layer_count * @sizeOf([*]BitmapEntry))))[0..layer_count];
        for (0..layer_count) |i| {
            const al: [*]BitmapEntry = @ptrFromInt(try allocator.alloc(@as(usize, @intCast(2)) << @truncate(layer_count - i)));
            ctx.bmp[i] = al[0 .. @as(usize, @intCast(2)) << @truncate(layer_count - i)];
            @memset(ctx.bmp[i][0 .. @as(usize, @intCast(2)) << @truncate(layer_count - i)], BitmapEntry{ .restricted = false, .unused = 0, .used = false, .allocation_origin = false });
        }

        const first_layer_size = @as(usize, @intCast(1)) << @truncate(layer_count);
        const pages_to_reserve = first_layer_size - (memsize) / page_size;
        // std.log.warn("first layer size: {x}, memsize: {x}, pageno: {}\n", .{ first_layer_size, in.memsize / in.page_size, pages_to_reserve });
        try ctx.reserve_address(memsize, pages_to_reserve, true);
        return ctx;
    }
    pub fn reserve_address(self: *BuddyContext, address: usize, pageno: usize, restricted: bool) !void {
        const p_2 = std.math.log2_int(usize, pageno);
        const size = @as(usize, @intCast(1)) << @truncate(p_2);
        // std.debug.print("p-2: {}, e: {}", .{ p_2, address / (size * self.page_size) });
        if (self.bmp[p_2][address / (size * self.page_size)].restricted == true) return error.CantEditAlreadyReserved;
        self.bmp[p_2][address / (size * self.page_size)].restricted = restricted;
        self.bmp[p_2][address / (size * self.page_size)].used = true;
        self.bmp[p_2][address / (size * self.page_size)].allocation_origin = true;
        var ind: usize = address / (size * self.page_size);
        for (p_2..self.bmp.len) |i| {
            ind /= 2;
            // std.log.warn("(RESERVE) setting layer: {}, index: {} to restricted\n", .{
            //     i,
            //     ind,
            // });
            self.bmp[i][ind] = BitmapEntry{ .restricted = restricted, .unused = 0, .used = true, .allocation_origin = false };
        }
    }

    pub fn alloc(self: *BuddyContext, pageno: usize) !usize {
        const layer_to_search = std.math.log2_int_ceil(usize, pageno);
        // std.log.warn("size of power of 2: {} allocation is {x}", .{ layer_to_search, (@as(usize, @intCast(2)) << @truncate(self.layers - layer_to_search)) });
        ol: for (0..(@as(usize, @intCast(2)) << @truncate(self.layers - layer_to_search))) |i| {
            // std.log.warn(" {}:{}, {any}\n", .{ layer_to_search, i, self.bmp[layer_to_search][i] });
            if (self.bmp[layer_to_search][i].used == false and self.bmp[layer_to_search][i].restricted != true) {
                // self.set_higher_lvls(layer_to_search, i, BitmapEntry{ .used = true, .restricted = false, .unused = 0 });
                var ind: usize = i;
                for (layer_to_search..self.layers) |ii| {
                    ind /= 2;
                    if (self.bmp[ii][ind].allocation_origin == true) {
                        // std.log.warn("allocation invalid: layer-{}, index-{}\n", .{ ii, ind });
                        continue :ol;
                    }
                }
                self.bmp[layer_to_search][i].allocation_origin = true;
                self.bmp[layer_to_search][i].used = true;
                ind = i / 2;
                for (layer_to_search + 1..self.bmp.len) |ii| {
                    ind /= 2;
                    self.bmp[ii][ind] = BitmapEntry{ .restricted = false, .unused = 0, .used = true, .allocation_origin = false };
                }
                const res = ((@as(usize, @intCast(1)) << @truncate(layer_to_search)) * self.page_size) * i;
                // std.log.warn("returning: 0x{x}\n", .{res});
                return res;
            }
        }
        return error.OutOfMemory;
    }
    inline fn get_buddy(orig_ind: usize) usize {
        if (orig_ind % 2 == 0) {
            return orig_ind + 1;
        } else {
            return orig_ind - 1;
        }
    }
    pub fn free(self: *BuddyContext, addr: usize) void {
        var ind = (addr / self.page_size);

        // std.log.warn("freeing address: {x}\n", .{addr});
        for (0..self.layers) |i| {
            // std.log.warn("checking {}:{}\n", .{ i, ind });
            if (self.bmp[i][ind].used == true) {
                // std.log.warn("found layer allocated: {}\n", .{i});
                for (i..self.layers) |ii| {
                    // std.log.warn("Checking buddy: {any} at layer: {}, index: {} ({})\n", .{ self.bmp[ii - 1][get_buddy(ind)], ii - 1, get_buddy(ind), ind });
                    if (ii != 0 and self.bmp[ii - 1][get_buddy(ind)].used == true) {
                        return;
                    }
                    ind /= 2;
                    // std.log.warn("setting : l{}:i{} to unused\n", .{ ii, ind });
                    self.bmp[ii][ind].used = false;
                }
                return;
            }
            ind /= 2;
        }
        // std.log.err("Free failed\n", .{});
    }
};
