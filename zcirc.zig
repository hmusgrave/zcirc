const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Chunk = struct {
    start: usize = 0,  
    len: usize = 0,
    data: []u8,

    pub fn clear(self: *@This()) void {
        self.start = 0;
        self.len = 0;
    }

    pub fn alloc(self: *@This(), n: usize) ?[]u8 {
        if (self.start + self.len + n <= self.data.len) {
            defer self.len += n;
            const x = self.start + self.len;
            return self.data[x..x+n];
        }
        return null;
    }

    pub fn is_empty(self: *@This()) bool {
        return self.len==0;
    }

    pub fn count(self: *@This()) usize {
        return self.len;
    }

    pub fn free_left(self: *@This(), first_kept: usize) void {
        const diff = first_kept - self.start;
        self.start += diff;
        self.len -= diff;
        if (self.len == 0)
            self.start = 0;
    }

    pub fn free_right(self: *@This(), first_removed: usize) void {
        if (first_removed == 0) {
            self.start = 0;
            self.len = 0;
        } else {
            var last_kept = first_removed - 1;
            const diff = self.start + self.len - last_kept - 1;
            self.len -= diff;
            if (self.len == 0)
                self.start = 0;
        }
    }
};

fn index_of(arr: anytype, el: *@typeInfo(@TypeOf(arr.ptr)).Pointer.child) usize {
    const T = @typeInfo(@TypeOf(arr.ptr)).Pointer.child;
    return (@ptrToInt(el) - @ptrToInt(arr.ptr)) / @sizeOf(T);
}

const Chunks = struct {
    start: usize = 0,
    len: usize = 1,
    chunks: []Chunk,

    pub fn count(self: *@This()) usize {
        var total: usize = 0;
        for (self.chunks[self.start..self.start+self.len]) |*c|
            total += c.count();
        return total;
    }

    pub fn clear(self: *@This()) void {
        for (self.chunks) |*c|
            c.clear();
        self.start = 0;
        self.len = 1;
    }

    pub fn alloc(self: *@This(), n: usize) ?[]u8 {
        const first_i = self.start + self.len - 1;
        for (self.chunks[first_i..]) |*c,i| {
            if (c.alloc(n)) |buf| {
                self.len += i;
                return buf;
            }
        }
        return null;
    }

    pub fn is_empty(self: *@This()) bool {
        return self.len==1 and self.chunks[self.start].is_empty();
    }

    pub fn free_left(self: *@This(), chunk: *Chunk, first_kept: usize) void {
        chunk.free_left(first_kept);
        const chunk_i = index_of(self.chunks, chunk) + @boolToInt(chunk.is_empty());
        const diff = chunk_i - self.start;
        for (self.chunks[self.start..chunk_i]) |*c|
            c.clear();
        self.start = chunk_i;
        self.len -= diff;
        if (self.len==0 or self.is_empty()) {
            self.start = 0;
            self.len = 1;
        }
    }

    pub fn free_right(self: *@This(), chunk: *Chunk, first_removed: usize) void {
        chunk.free_right(first_removed);
        const N = index_of(self.chunks, chunk) + @boolToInt(chunk.len!=0) - self.start;
        for (self.chunks[self.start+N..self.start+self.len]) |*c|
            c.clear();
        self.len = N;
        if (self.len==0 or self.is_empty()) {
            self.start = 0;
            self.len = 1;
        }
    }
};

pub fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a>b) a else b;
}

pub fn min(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a<b) a else b;
}

fn extend(arr: anytype, n: usize) @TypeOf(arr) {
    const T = @typeInfo(@TypeOf(arr)).Pointer.child;
    var ptr = @intToPtr([*]T, @ptrToInt(arr.ptr));
    return ptr[0..n+arr.len];
}

const Buffer = struct {
    chunk_buf: [64]Chunk = undefined,
    last_size: usize = 1024,
    next_chunk: usize = 0,
    left: ?Chunks = null,
    right: ?Chunks = null,
    overflow: ?Chunks = null,
    allocator: Allocator,

    pub fn count(self: *@This()) usize {
        var total: usize = 0;
        if (self.left) |*x|
            total += x.count();
        if (self.right) |*x|
            total += x.count();
        if (self.overflow) |*x|
            total += x.count();
        return total;
    }

    pub fn deinit(self: *@This()) void {
        if (self.next_chunk>0) {
            for (self.slice()) |*c|
                self.allocator.free(c.data);
        }
    }

    fn new_chunk(self: *@This(), n: usize) !*Chunk {
        if (self.next_chunk >= self.chunk_buf.len) {
            // shouldn't happen often, would require at least
            // 16 exabytes of RAM and usize>u64
            return error.OutOfMemory;
        }
        var rtn = &self.chunk_buf[self.next_chunk];
        self.next_chunk += 1;
        const N = max(self.last_size, n) * 2;
        self.last_size = N;
        rtn.* = .{
            .data = try self.allocator.alloc(u8, N),
        };
        return rtn;
    }

    fn slice(self: *@This()) []Chunk {
        return self.chunk_buf[0..self.next_chunk];
    }

    const Response = struct {
        buf: []u8,
        chunk: *Chunk,
    };

    pub fn alloc(self: *@This(), n: usize) !Response {
        // First allocation
        if (self.next_chunk == 0) {
            _ = try self.new_chunk(n);
            self.left = Chunks{.chunks=self.slice()[0..1]};
            var rtn = self.left.?.alloc(n).?;
            return Response{
                .buf = rtn,
                .chunk = &self.slice()[0],
            };
        }

        // If we have an overflow buffer, new allocations always go there
        if (self.overflow) |*ov| {
            if (ov.alloc(n)) |buf|
                return Response{
                    .buf = buf,
                    .chunk = &ov.chunks[ov.start+ov.len-1],
                };
            _ = try self.new_chunk(n);
            ov.chunks = extend(ov.chunks, 1);
            var rtn = ov.alloc(n).?;
            return Response{
                .buf = rtn,
                .chunk = &ov.chunks[ov.start+ov.len-1],
            };
        }

        // If we have one circular buffer half it's stored in `left`, and
        // if we have two then new allocations still go in the left
        if (self.left.?.alloc(n)) |buf| {
            var left = &self.left.?;
            return Response{
                .buf = buf,
                .chunk = &left.chunks[left.start+left.len-1],
            };
        }

        // If we've gotten this far, there isn't an overflow, there is a
        // circular buffer, and there isn't room in that buffer for new
        // stuff. We need to create an overflow region.
        {
            _ = try self.new_chunk(n);
            self.overflow = Chunks{.chunks=self.slice()[self.next_chunk-1..]};
            var ov = &self.overflow.?;
            var rtn = ov.alloc(n).?;
            return Response{
                .buf = rtn,
                .chunk = &ov.chunks[0],
            };
        }
    }

    fn in_overflow(self: *@This(), chunk: *Chunk) bool {
        if (self.overflow) |*ov| {
            return @ptrToInt(chunk) >= @ptrToInt(ov.chunks.ptr);
        }
        return false;
    }

    fn in_left(self: *@This(), chunk: *Chunk) bool {
        if (self.left) |*left| {
            var boundary = @ptrToInt(left.chunks.ptr) + left.chunks.len * @sizeOf(Chunk);
            return @ptrToInt(chunk) < boundary;
        }
        return false;
    }

    pub fn free_left(self: *@This(), chunk: *Chunk, data: []u8) void {
        const first_kept = @ptrToInt(data.ptr) + data.len - @ptrToInt(chunk.data.ptr);
        if (self.in_overflow(chunk)) {
            self.left.?.clear();
            if (self.right) |*x|
                x.clear();
            var ov = &self.overflow.?;
            ov.free_left(chunk, first_kept);
            if (ov.is_empty()) {
                self.left = Chunks{.chunks=self.slice()};
                self.right = null;
                self.overflow = null;
            } else {
                const i = index_of(self.slice(), &ov.chunks[ov.start]);
                self.left = Chunks{.chunks=self.slice()[0..i]};
                self.right = Chunks{.chunks=self.slice()[i..]};
                self.right.?.len = ov.len;
                self.overflow = null;
            }
        } else if (self.right) |*right| {
            if (self.in_left(chunk)) {
                right.clear();
                var left = &self.left.?;
                left.free_left(chunk, first_kept);
                left.chunks = extend(left.chunks, right.chunks.len);
                left.chunks = left.chunks[left.start..];
                left.start = 0;
                self.right = left.*;
                const i = index_of(self.slice(), &left.chunks[left.start]);
                if (i == 0) {
                    self.left = self.right;
                    self.right = null;
                } else {
                    self.left = Chunks{.chunks=self.slice()[0..i]};
                }
            } else {
                right.free_left(chunk, first_kept);
                if (right.is_empty()) {
                    self.left.?.chunks = extend(self.left.?.chunks, right.chunks.len);
                    self.right = null;
                } else {
                    const N = right.start;
                    right.chunks = right.chunks[right.start..];
                    right.start = 0;
                    self.left.?.chunks = extend(self.left.?.chunks, N);
                }
            }
        } else {
            var left = &self.left.?;
            left.free_left(chunk, first_kept);
            const i = left.start;
            if (i > 0) {
                self.right = left.*;
                left.chunks = left.chunks[i..];
                left.start = 0;
                self.left = Chunks{.chunks=self.slice()[0..i]};
            }
        }
    }

    pub fn free_right(self: *@This(), chunk: *Chunk, data: []u8) void {
        const first_removed = @ptrToInt(data.ptr) - @ptrToInt(chunk.data.ptr);
        if (self.in_overflow(chunk)) {
            var ov = &self.overflow.?;
            ov.free_right(chunk, first_removed);
            if (ov.is_empty()) {
                if (self.right) |*right| {
                    right.chunks = extend(right.chunks, ov.chunks.len);
                } else {
                    self.right = ov.*;
                }
                self.overflow = null;
            }
        } else if (self.right) |*right| {
            var left = &self.left.?;
            if (self.overflow) |*ov|
                ov.clear();
            if (self.in_left(chunk)) {
                left.free_right(chunk, first_removed);
                if (left.is_empty()) {
                    const i = index_of(self.slice(), &right.chunks[right.start]);
                    right.chunks = self.slice()[i..];
                    self.overflow = null;
                }
            } else {
                left.clear();
                right.free_right(chunk, first_removed);
                if (right.is_empty()) {
                    self.left = Chunks{.chunks=self.slice()};
                    self.right = null;
                    self.overflow = null;
                } else {
                    const i = index_of(self.slice(), &right.chunks[right.start]);
                    self.left = Chunks{.chunks=self.slice()[0..i]};
                    right.chunks = right.chunks[right.start..];
                    right.start = 0;
                }
            }
        } else {
            var left = &self.left.?;
            if (self.overflow) |*ov|
                ov.clear();
            left.free_right(chunk, first_removed);
            if (left.is_empty()) {
                self.overflow = null;
                self.left = Chunks{.chunks=self.slice()};
            }
        }
    }
};

pub const CircularAllocator = struct {
    buffer: Buffer,

    const Meta = struct {
        start_unused: u32,
        total_unused: u32,
        chunk_i: u8,
    };

    pub fn count(self: *@This()) usize {
        return self.buffer.count();
    }

    pub fn init(child_allocator: Allocator) @This() {
        return .{
            .buffer = .{
                .allocator = child_allocator,
            },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.buffer.deinit();
    }

    pub fn allocator(self: *@This()) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    fn alloc(self: *@This(), n: usize, ptr_align: u29, _: u29, _: usize) ![]u8 {
        var resp = try self.buffer.alloc(n + @sizeOf(Meta) + ptr_align + @alignOf(Meta) - 2);
        var buf = resp.buf;

        const addr = @ptrToInt(buf.ptr);
        const adjusted_addr = mem.alignForward(addr, ptr_align);
        const end_idx = adjusted_addr + n;

        const pred_addr = mem.alignForward(end_idx, @alignOf(Meta));
        @intToPtr(*Meta, pred_addr).* = .{
            .start_unused = @intCast(u32, adjusted_addr - addr),
            .total_unused = @intCast(u32, buf.len - n),
            .chunk_i = @intCast(u8, index_of(self.buffer.slice(), resp.chunk)),
        };

        return buf[adjusted_addr-addr..end_idx-addr];
    }

    const Response = struct {
        buf: []u8,
        chunk: *Chunk,
    };

    fn _whole_buf(self: *@This(), data: []u8) Response {
        const s = @ptrToInt(data.ptr);
        const e = s + data.len;
        const meta = @intToPtr(*Meta, mem.alignForward(e, @alignOf(Meta))).*;
        var ptr = @intToPtr([*]u8, s-meta.start_unused);
        return Response{
            .buf = ptr[0..data.len+meta.total_unused],
            .chunk = &self.buffer.slice()[@intCast(usize, meta.chunk_i)],
        };
    }

    fn whole_buf(self: *@This(), data: anytype) Response {
        const ti = @typeInfo(@TypeOf(data)).Pointer;
        const N = @sizeOf(ti.child);

        var buf = switch (ti.size) {
            .One => @intToPtr([*]u8, @ptrToInt(data))[0..N],
            .Slice => @intToPtr([*]u8, @ptrToInt(data.ptr))[0..N*data.len],
            else => @compileError("Unsupported data type"),
        };

        return self._whole_buf(buf);
    }

    pub fn free_left(self: *@This(), data: anytype) void {
        var resp = self.whole_buf(data);
        self.buffer.free_left(resp.chunk, resp.buf);
    }

    pub fn free_right(self: *@This(), data: anytype) void {
        var resp = self.whole_buf(data);
        self.buffer.free_right(resp.chunk, resp.buf);
    }

    fn free(_: *@This(), _: []u8, _: u29, _: usize) void {
    }

    fn resize(_: *@This(), _: []u8, _: u29, _: usize, _: u29, _: usize) ?usize {
        return null;
    }

};

test "CircularAllocator" {
    // We're just doing a few operations and verifying that allocations
    // are the right size and that nothing obviously crashes.

    // setup
    var c = CircularAllocator.init(std.testing.allocator);
    defer c.deinit();
    var allocator = c.allocator();

    // a couple buffers
    var buf = try allocator.alloc(u8, 4);
    var buf2 = try allocator.alloc(u8, 12);

    // at all times we have 2 buffers, moving rightward through
    // the buffer -- (a,b) -> (b,c) -> (c,d)
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        c.free_left(buf);
        buf = buf2;
        buf2 = try allocator.alloc(u8, 7);
        try expectEqual(@as(usize, 7), buf2.len);
    }

    // clean everything up
    c.free_right(buf2);
    c.free_right(buf);
    try expectEqual(@as(usize, 0), c.count());

    // make a few allocations and then walk backward
    // freeing them from the right
    var dat: [100][]u8 = undefined;
    i = 0;
    while (i < 100) : (i += 1) {
        dat[i] = try allocator.alloc(u8, 12);
        try expectEqual(@as(usize, 12), dat[i].len);
    }
    i = 0;
    while (i < 100) : (i += 3) {
        c.free_right(dat[99-i]);
    }
    try expectEqual(@as(usize, 0), c.count());
}
