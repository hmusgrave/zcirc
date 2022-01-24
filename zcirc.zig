const std = @import("std");
const mem = std.mem;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const Tree = @import("SplayGLB.zig").Tree;

inline fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a>b) a else b;
}

inline fn min(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a<b) a else b;
}

const Chunk = struct {
    left: usize = 0,
    len: usize = 0,
    last: usize = 0,
    data: []u8,

    pub fn reset(self: *@This()) void {
        self.left = 0;
        self.len = 0;
        self.last = 0;
    }

    pub fn alloc(self: *@This(), n: usize) ?[]u8 {
        if (self.left + self.len + n <= self.data.len) {
            defer self.len += n;
            defer self.last += n;
            return self.data[self.left + self.len .. ][0..n];
        }
        return null;
    }

    pub fn free_left(self: *@This(), data: []u8) void {
        const i = @ptrToInt(data.ptr) - @ptrToInt(self.data.ptr);
        self.len -= i + data.len - self.left;
        self.left = i + data.len;
    }

    pub fn free_right(self: *@This(), data: []u8) void {
        const i = @ptrToInt(data.ptr) - @ptrToInt(self.data.ptr);
        self.len = i - self.left;
        self.last = i;
    }
};

test "Chunk" {
    var data = try std.testing.allocator.alloc(u8, 100);
    defer std.testing.allocator.free(data);
    var chunk = Chunk{.data = data};
    var x = chunk.alloc(99);
    try expectEqual(x, data[0..99]);
    x = chunk.alloc(1);
    try expectEqual(x, data[99..]);
    x = chunk.alloc(5);
    try expectEqual(x, null);
    chunk.free_left(data[0..99]);
    x = chunk.alloc(5);
    try expectEqual(x, null);
    chunk.free_right(data[99..]);
    x = chunk.alloc(5);
    try expectEqual(x, null);
    x = chunk.alloc(1);
    try expectEqual(x, data[99..]);
}

const Chunks = struct {
    next_loc: usize = 0,
    buffer: [64]Chunk = undefined,

    pub inline fn alloc(self: *@This(), chunk: Chunk) *Chunk {
        var rtn = &self.buffer[self.next_loc];
        rtn.* = chunk;
        self.next_loc += 1;
        return rtn;
    }

    pub inline fn slice(self: *@This()) []Chunk {
        return self.buffer[0..self.next_loc];
    }
};

const CircleAllocator = struct {
    //
    // A dynamic circular buffer which doesn't copy on resize
    //
    // TODO: chunk.reset() can be lazily evaluated only on chunks
    //       which need it
    left: usize = 0,
    len: usize = 0,
    last: usize = 0,
    overflow: usize = 0,
    last_overflow: usize = 0,
    chunks: Chunks = .{},
    child_allocator: Allocator,
    chunk_edges: Tree(usize) = .{},
    data_to_chunk: std.AutoHashMap(usize, *Chunk),

    pub fn init(child_allocator: Allocator) @This() {
        return .{
            .child_allocator = child_allocator,
            .data_to_chunk = std.AutoHashMap(usize, *Chunk).init(child_allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.chunks.slice()) |*c|
            self.child_allocator.free(c.data);
        self.data_to_chunk.deinit();
    }

    pub fn allocator(self: *@This()) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    pub fn total_bytes(self: *@This()) usize {
        var total: usize = 0;
        for (self.chunks.slice()) |*chunk|
            total += chunk.len;
        return total;
    }

    fn new_chunk(self: *@This(), n: usize) ![]u8 {
        const slice = self.chunks.slice();
        const N = 2 * (if (slice.len > 0) max(n, slice[slice.len-1].data.len) else n);
        var chunk = self.chunks.alloc(.{
            .data = try self.child_allocator.alloc(u8, N),
        });
        const U = @ptrToInt(chunk.data.ptr);
        self.chunk_edges.add(U);
        try self.data_to_chunk.put(U, chunk);
        self.last_overflow = slice.len+1;
        if (self.left + self.len + 1 == slice.len) {
            self.overflow = slice.len + 1;
            self.last_overflow = slice.len + 1;
            self.last = slice.len + 1;
            self.len = self.last - self.left;
        }
        return chunk.alloc(n).?;
    }

    fn _alloc(self: *@This(), n: usize) ![]u8 {
        // save some typing
        var slice = self.chunks.slice();

        // First allocation should be fast
        if (slice.len == 0)
            return self.new_chunk(n);

        // If the overflow is nonempty, shove stuff there
        if (self.overflow < slice.len) {
            for (slice[self.last_overflow-1..]) |*chunk,i| {
                if (chunk.alloc(n)) |buf| {
                    self.last_overflow += i;
                    return buf;
                }
            }
            return self.new_chunk(n);
        }

        // If we aren't storing anything, start at the far left
        if (self.len == 0) {
            for (slice) |*chunk,i| {
                if (chunk.alloc(n)) |buf| {
                    self.left = i;
                    self.len = i + 1;
                    self.last = i + 1;
                    return buf;
                }
            }
            return self.new_chunk(n);
        }

        // If there's room at the right of the buffer, use that
        for (slice[min(self.left + self.len - 1, slice.len)..]) |*chunk,i| {
            if (chunk.alloc(n)) |buf| {
                self.len += i;
                self.last += i;
                return buf;
            }
        }

        // If there's room at the left of the buffer, do that instead
        const right = self.len - (self.last - self.left);
        if (right == 0) {
            for (slice[0..self.left]) |*chunk,i| {
                if (chunk.alloc(n)) |buf| {
                    self.len = (i+1) + (self.last - self.left);
                    return buf;
                }
            }
        }
        for (slice[right-1..self.left]) |*chunk,i| {
            if (chunk.alloc(n)) |buf| {
                self.len += i;
                return buf;
            }
        }

        // Shove stuff in the overflow
        return self.new_chunk(n);
    }

    fn alloc(self: *@This(), n: usize, ptr_align: u29, _: u29, _: usize) ![]u8 {
        // [unused, data, unused, start.unused.len, ptr_align, unused];
        var buf = try self._alloc(n + 12 + ptr_align);

        const addr = @ptrToInt(buf.ptr);
        const adjusted_addr = mem.alignForward(addr, ptr_align);
        const end_idx = adjusted_addr + n;

        const pred_addr = mem.alignForward(end_idx, @alignOf(u32));
        @intToPtr(*u32, pred_addr).* = @truncate(u32, adjusted_addr - addr);
        @intToPtr(*u32, pred_addr + @sizeOf(u32)).* = @intCast(u32, ptr_align);

        return buf[adjusted_addr-addr..end_idx-addr];
    }

    fn free(_: *@This(), _: []u8, _: u29, _: usize) void {
    }

    fn resize(_: *@This(), _: []u8, _: u29, _: usize, _: u29, _: usize) ?usize {
        return null;
    }

    fn trash_left(self: *@This(), chunk: *Chunk) void {
        var slice = self.chunks.slice();
        const chunk_offset = (@ptrToInt(chunk) - @ptrToInt(slice.ptr)) / @sizeOf(Chunk);
        if (chunk_offset >= self.overflow) {
            for (slice[0..chunk_offset]) |*c|
                c.reset();
            self.left = chunk_offset;
            self.last = chunk_offset+1;
            self.len = 1;
            self.overflow = slice.len;
            self.last_overflow = slice.len;
        } else if (chunk_offset >= self.left) {
            for (slice[self.left..chunk_offset]) |*c|
                c.reset();
            self.len -= (chunk_offset - self.left);
            self.left = chunk_offset;
        } else {
            const right = self.len - (self.last - self.left);
            for (slice[0..chunk_offset]) |*c|
                c.reset();
            for (slice[right..]) |*c|
                c.reset();
            self.len = right - chunk_offset;
            self.left = chunk_offset;
            self.last = right;
        }
    }

    fn trash_right(self: *@This(), chunk: *Chunk) void {
        var slice = self.chunks.slice();
        const chunk_offset = (@ptrToInt(chunk) - @ptrToInt(slice.ptr)) / @sizeOf(Chunk);
        if (chunk_offset >= self.overflow) {
            self.last_overflow = chunk_offset + 1;
            for (slice[chunk_offset+1..]) |*c|
                c.reset();
        } else if (chunk_offset >= self.left) {
            self.len = chunk_offset - self.left + 1;
            self.last = self.left + self.len;
            self.overflow = slice.len;
            self.last_overflow = slice.len;
            for (slice[0..self.left]) |*c|
                c.reset();
            for (slice[chunk_offset+1..]) |*c|
                c.reset();
        } else {
            const right = self.len - (self.last - self.left);
            self.len -= right - (chunk_offset+1);
            self.last_overflow = self.overflow+1;
            for (slice[self.overflow..]) |*c|
                c.reset();
            for (slice[chunk_offset+1..self.left]) |*c|
                c.reset();
        }
    }

    fn _free_left(self: *@This(), data: []u8) void {
        const U = self.chunk_edges.glb(@ptrToInt(data.ptr)).?;
        var chunk = self.data_to_chunk.get(U).?;
        var slice = self.chunks.slice();
        const chunk_offset = (@ptrToInt(chunk) - @ptrToInt(slice.ptr)) / @sizeOf(Chunk);
        const data_offset = @ptrToInt(data.ptr) - @ptrToInt(chunk.data.ptr);
        if (data_offset + data.len == chunk.data.len) {
            if (chunk_offset+1 < slice.len) {
                self.trash_left(&self.chunks.slice()[chunk_offset+1]);
            } else {
                self.left = 0;
                self.last = 0;
                self.len = 0;
                self.overflow = slice.len;
                self.last_overflow = slice.len;
            }
        } else {
            chunk.free_left(data);
            self.trash_left(chunk);
        }
    }

    pub fn free_left(self: *@This(), data: anytype) void {
        const T = @TypeOf(data);
        const Pointer = @typeInfo(T).Pointer;
        const ChildT = Pointer.child;
        switch (Pointer.size) {
            .One => {
                const idx = @ptrToInt(data);
                const end_idx = idx + @sizeOf(ChildT);
                const addr = mem.alignForward(end_idx, @alignOf(u32));
                const start_unused = @intToPtr(*u32, addr).*;
                const total_unused = 12 + @intToPtr(*u32, addr+@sizeOf(u32)).*;
                var many = @intToPtr([*]u8, idx - start_unused);
                var buf = many[0..@sizeOf(ChildT)+total_unused];
                self._free_left(buf);
            },
            .Slice => {
                const idx = @ptrToInt(data.ptr);
                const end_idx = idx + data.len;
                const addr = mem.alignForward(end_idx, @alignOf(u32));
                const start_unused = @intToPtr(*u32, addr).*;
                const total_unused = 12 + @intToPtr(*u32, addr+@sizeOf(u32)).*;
                var many = @intToPtr([*]u8, idx-start_unused);
                var buf = many[0..@sizeOf(ChildT)*data.len+total_unused];
                self._free_left(buf);
            },
            else => unreachable,
        }
    }
    
    fn _free_right(self: *@This(), data: []u8) void {
        const U = self.chunk_edges.glb(@ptrToInt(data.ptr)).?;
        var chunk = self.data_to_chunk.get(U).?;
        var slice = self.chunks.slice();
        const chunk_offset = (@ptrToInt(chunk) - @ptrToInt(slice.ptr)) / @sizeOf(Chunk);
        const data_offset = @ptrToInt(data.ptr) - @ptrToInt(chunk.data.ptr);
        if (data_offset == 0) {
            if (chunk_offset > 0) {
                self.trash_right(&self.chunks.slice()[chunk_offset-1]);
            } else {
                self.left = 0;
                self.last = 0;
                self.len = 0;
                self.overflow = slice.len;
                self.last_overflow = slice.len;
            }
        } else {
            chunk.free_right(data);
            self.trash_right(chunk);
        }
    }

    pub fn free_right(self: *@This(), data: anytype) void {
        const T = @TypeOf(data);
        const Pointer = @typeInfo(T).Pointer;
        const ChildT = Pointer.child;
        switch (Pointer.size) {
            .One => {
                const idx = @ptrToInt(data);
                const end_idx = idx + @sizeOf(ChildT);
                const addr = mem.alignForward(end_idx, @alignOf(u32));
                const start_unused = @intToPtr(*u32, addr).*;
                const total_unused = 12 + @intToPtr(*u32, addr+@sizeOf(u32)).*;
                var many = @intToPtr([*]u8, idx - start_unused);
                var buf = many[0..@sizeOf(ChildT)+total_unused];
                self._free_right(buf);
            },
            .Slice => {
                const idx = @ptrToInt(data.ptr);
                const end_idx = idx + data.len;
                const addr = mem.alignForward(end_idx, @alignOf(u32));
                const start_unused = @intToPtr(*u32, addr).*;
                const total_unused = 12 + @intToPtr(*u32, addr+@sizeOf(u32)).*;
                var many = @intToPtr([*]u8, idx-start_unused);
                var buf = many[0..@sizeOf(ChildT)*data.len+total_unused];
                self._free_right(buf);
            },
            else => unreachable,
        }
    }
};

test "CircleAllocator" {
    var circle = CircleAllocator.init(std.testing.allocator);
    defer circle.deinit();
    var allocator = circle.allocator();

    var buffer = try allocator.alloc(u8, 12);
    try expectEqual(@as(usize, 12), buffer.len);
    try expectEqual(@TypeOf(buffer), []u8);

    var buffer2 = try allocator.alloc(u8, 58);
    try expectEqual(@as(usize, 58), buffer2.len);
    try expect(@ptrToInt(buffer.ptr) != @ptrToInt(buffer2.ptr));

    var buffer3 = try allocator.alloc(u8, 2);
    try expect(@ptrToInt(buffer2.ptr) < @ptrToInt(buffer3.ptr));

    circle.free_left(buffer3);
    try expectEqual(@as(usize, 0), circle.total_bytes());

    buffer = try allocator.alloc(u8, 28);
    try expectEqual(@as(usize, 28 + 12 + @alignOf(u8)), circle.total_bytes());
    circle.free_right(buffer);
    try expectEqual(@as(usize, 0), circle.total_bytes());
}
