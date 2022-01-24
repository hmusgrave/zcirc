const expectEqual = @import("std").testing.expectEqual;

pub fn Tree(comptime T: type) type {
    // Loosely based on a traditional splay tree. We know we'll
    // have a small (<=64) number of nodes, we'll never try to
    // add duplicate keys, we'll never need to delete nodes,
    // and we need to optimize for greatest lower bound searches,
    // which requires that the (<=N) and immediate (>N) nodes are
    // adjacent in the tree and have null children to short
    // circuit further searching.
    const Node = struct {
        key: T,
        left: ?*@This() = null,
        right: ?*@This() = null,
        parent: ?*@This() = null,
    };

    return struct {
        root: ?*Node = null,
        data: [64]Node = undefined,
        next_loc: usize = 0,

        pub fn add(self: *@This(), key: T) void {
            var node = self._add(key);
            self.splay(node);
            self._compress();
        }

        inline fn splay(self: *@This(), node: *Node) void {
            while (node != self.root.?)
                self._splay(node);
        }

        fn _splay(self: *@This(), node: *Node) void {
            if (node == self.root) {
            } else if (node.parent == self.root) {
                node.parent = null;
                self.root.?.parent = node;
                if (self.root.?.left == node) {
                    self.root.?.left = node.right;
                    if (node.right) |*r|
                        r.*.parent = self.root;
                    node.right = self.root;
                } else {
                    self.root.?.right = node.left;
                    if (node.left) |*l|
                        l.*.parent = self.root;
                    node.left = self.root;
                }
                self.root = node;
            } else if (node.parent.?.left == node and
            node.parent.?.parent.?.left == node.parent or node.parent.?.right
            == node and node.parent.?.parent.?.right == node.parent) {
                var x = node;
                var p = node.parent.?;
                var g = p.parent.?;
                var gg = g.parent;
                if (g.left == p) {
                    g.left = p.right;
                    if (p.right) |*r|
                        r.*.parent = g;
                    p.left = x.right;
                    if (x.right) |*r|
                        r.*.parent = p;
                    x.right = p;
                    p.parent = x;
                    p.right = g;
                    g.parent = p;
                    x.parent = gg;
                    if (gg) |*r| {
                        if (r.*.right == g) {
                            r.*.right = x;
                        } else {
                            r.*.left = x;
                        }
                    } else {
                        self.root = x;
                    }
                } else {
                    g.right = p.left;
                    if (p.left) |*l|
                        l.*.parent = g;
                    p.right = x.left;
                    if (x.left) |*l|
                        l.*.parent = p;
                    x.left = p;
                    p.parent = x;
                    p.left = g;
                    g.parent = p;
                    x.parent = gg;
                    if (gg) |*l| {
                        if (l.*.left == g) {
                            l.*.left = x;
                        } else {
                            l.*.right = x;
                        }
                    } else {
                        self.root = x;
                    }
                }
            } else {
                var x = node;
                var p = node.parent.?;
                var g = p.parent.?;
                var gg = g.parent;
                if (g.left == p) {
                    g.left = x.right;
                    p.right = x.left;
                    x.right = g;
                    x.left = p;
                    p.parent = x;
                    g.parent = x;
                    x.parent = gg;
                    if (g.left) |*z|
                        z.*.parent = g;
                    if (p.right) |*z|
                        z.*.parent = p;
                    if (gg) |*z| {
                        if (z.*.left == g) {
                            z.*.left = x;
                        } else {
                            z.*.right = x;
                        }
                    } else {
                        self.root = x;
                    }
                } else {
                    g.right = x.left;
                    p.left = x.right;
                    x.left = g;
                    x.right = p;
                    p.parent = x;
                    g.parent = x;
                    x.parent = gg;
                    if (g.right) |*z|
                        z.*.parent = g;
                    if (p.left) |*z|
                        z.*.parent = p;
                    if (gg) |*z| {
                        if (z.*.right == g) {
                            z.*.right = x;
                        } else {
                            z.*.left = x;
                        }
                    } else {
                        self.root = x;
                    }
                }
            }
        }

        fn _add(self: *@This(), key: T) *Node {
            if (self.root == null) {
                self.root = self.alloc(.{.key = key});
                return self.root.?;
            }
            var node = &self.root;
            var parent = self.root;
            while (node.*) |n| {
                parent = n;
                node = if (n.key < key) &n.right else &n.left;
            }
            node.* = self.alloc(.{.key = key});
            node.*.?.parent = parent;
            return node.*.?;
        }

        pub fn glb(self: *@This(), key: T) ?T {
            // greatest lower bound
            var node = &self.root;
            while (node.*) |n| {
                if (n.key == key) {
                    self.splay(n);
                    self._compress();
                    return key;
                }
                if (n.key < key) {
                    if (n.right) |_| {
                        node = &n.right;
                    } else {
                        self.splay(n);
                        self._compress();
                        return n.key;
                    }
                } else {
                    node = &n.left;
                }
            }
            return null;
        }

        fn _compress(self: *@This()) void {
            if (self.root) |*root| {
                if (root.*.right) |right| {
                    var node = right;
                    while (node.left) |n|
                        node = n;
                    if (node.parent == root.*)
                        return;
                    node.parent.?.left = node.right;
                    if (node.right) |*r|
                        r.*.parent = node.parent;
                    node.parent = root.*;
                    node.right = root.*.right;
                    root.*.right = node;
                    node.right.?.parent = node;
                }
            }
        }

        inline fn alloc(self: *@This(), node: Node) *Node {
            var rtn = &self.data[self.next_loc];
            rtn.* = node;
            self.next_loc += 1;
            return rtn;
        }
    };
}

fn expectSplayed(comptime T: type, tree: *Tree(T), glb: ?T, next: ?T) !void {
    // root == glb, root.right == next, root.right.left == null
    // for fast glb lookups in [glb, next)
    try expectEqual(glb, tree.root.?.key);
    if (tree.root.?.right) |r| {
        try expectEqual(next, r.key);
        try expectEqual(r.left, null);
    } else {
        try expectEqual(next, null);
    }
}

fn expectValid(comptime T: type, tree: *Tree(T), glb: ?T, next: ?T, query: T) !void {
    try expectEqual(glb, tree.glb(query));
    if (glb) |_|
        try expectSplayed(T, tree, glb, next);
}

test "something" {
    var _tree = Tree(u32){};
    var tree = &_tree;

    try expectValid(u32, tree, null, null, 1);

    tree.add(5);
    try expectValid(u32, tree, 5, null, 5);
    try expectValid(u32, tree, 5, null, 6);
    try expectValid(u32, tree, null, null, 4);

    tree.add(6);
    try expectValid(u32, tree, 5, 6, 5);
    try expectValid(u32, tree, 6, null, 6);
    try expectValid(u32, tree, null, null, 4);

    tree.add(4);
    try expectValid(u32, tree, 5, 6, 5);
    try expectValid(u32, tree, 6, null, 6);
    try expectValid(u32, tree, 4, 5, 4);
    try expectValid(u32, tree, null, null, 3);
}
