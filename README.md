# zcirc

A dynamic circular buffer allocator for zig

## Purpose

One use case for circular buffers is handling allocations that depend on
previous allocations, after which the previous data is no longer necessary.
This library handles that use case when you don't know ahead of time how much
memory you might need.

## Installation

Choose your favorite method for vendoring this code into your repository. I
think [git-subrepo](https://github.com/ingydotnet/git-subrepo) strikes a nicer
balance than git-submodules or most other alternatives.

When Zig gets is own builtin package manager we'll be available there as well.

```bash
git subrepo clone git+https://github.com/hmusgrave/zcirc.git [optional-subdir]
```

## Examples
```zig
const std = @import("std");
const CircularAllocator= @import("zcirc.zig").CircularAllocator;

test "something" {
    // Much like working with an ArenaAllocator
    var circle = CircularAllocator.init(std.testing.allocator);
    defer circle.deinit();
    var allocator = circle.allocator();

    // Allocations work like any other allocator
    var a = try allocator.create(u32);
    a.* = 12;
    var b = try allocator.alloc(u8, a.*);

    // The total "busy" bytes in our internal buffers include the
    // space for a and b, plus some slop for alignment and bookkeeping
    const overhead = @alignOf(CircularAllocator.Meta) + @sizeOf(CircularAllocator.Meta) - 2;
    try std.testing.expectEqual(
        (b.len + @sizeOf(u32)) + (@alignOf(u8) + @alignOf(u32)) + 2*overhead,
        circle.count()
    );

    // Deletes all data up through (including) the pointer `a`
    circle.free_left(a);

    // The total "busy" bytes only track space used for `b` now
    try std.testing.expectEqual(b.len + @alignOf(u8) + overhead, circle.count());

    // Deletes all data from (including) the slice `b`
    circle.free_right(b);

    // Our internal buffers are completely empty. New allocations will
    // attempt to reuse that space.
    try std.testing.expectEqual(@as(usize, 0), circle.count());
}
```

## Status
Contributions welcome. I'll check back on this repo at least once per month.
Currently targets Zig 0.10.*-dev.

The test suite isn't very complete yet, but any bugs should be superficial at
this point.
