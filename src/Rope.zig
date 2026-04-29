const std = @import("std");
const builtin = @import("builtin");
pub const Self = @This();

pub const Node = struct {
    pub const String = union(enum) {
        allocated: std.ArrayList(u8),
        read_only: []const u8,

        pub const empty = String{ .read_only = "" };

        pub fn len(self: *const String) usize {
            return switch (self.*) {
                .allocated => |list| list.items.len,
                .read_only => |slice| slice.len,
            };
        }

        pub fn items(self: *const String) []const u8 {
            return switch (self.*) {
                .allocated => |list| list.items,
                .read_only => |slice| slice,
            };
        }
    };

    string: String,
    total_length: usize,
    left: ?*Node = null,
    right: ?*Node = null,

    pub inline fn init(node: *Node, left: ?*Node, right: ?*Node) *Node {
        node.* = .{
            .string = .empty,
            .total_length = (if (left) |l| l.total_length else 0) + if (right) |r| r.total_length else 0,
            .left = left,
            .right = right,
        };
        return node;
    }

    pub inline fn isLeaf(self: *const Node) bool {
        if (builtin.mode == .Debug) {
            if (self.string.len() == 0)
                std.debug.assert(self.left != null or self.right != null)
            else
                std.debug.assert(self.left == null and self.right == null);
        }
        return self.string.len() != 0;
    }

    pub fn getNonLeafs(self: *Node, scratch: std.mem.Allocator) std.ArrayList(*Node) {
        var list = std.ArrayList(*Node).empty;
        self.getNonLeafsImpl(&list, scratch);
        return list;
    }

    pub fn getNonLeafsImpl(self: *Node, list: *std.ArrayList(*Node), scratch: std.mem.Allocator) void {
        if (!self.isLeaf()) {
            list.append(scratch, self) catch @panic("OOM");
            if (self.left) |left| {
                left.getNonLeafsImpl(list, scratch);
            }
            if (self.right) |right| {
                right.getNonLeafsImpl(list, scratch);
            }
        }
    }
};

allocator: std.mem.Allocator,
node_pool: std.heap.MemoryPool(Node),
root: ?*Node,
len: usize = 0,
balance_state: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .node_pool = .empty,
        .root = null,
    };
}

pub fn loadEmpty(self: *Self) void {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .string = .empty,
        .total_length = 0,
    };
    self.root = node;
    self.len = 0;
}

pub fn loadString(self: *Self, string: []const u8) void {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .string = .{ .read_only = string },
        .total_length = string.len,
    };
    self.root = node;
    self.len = string.len;
}

pub fn createNode(self: *Self, left: ?*Node, right: ?*Node) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    _ = node.init(left, right);
    return node;
}

pub fn createLeafNode(self: *Self, string: Node.String) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .string = string,
        .total_length = string.len(),
    };
    return node;
}

pub fn rebalance(self: *Self, scratch: std.mem.Allocator) void {
    if (self.root) |root| {
        const result, _ = self.rebalanceNode(root, scratch);
        self.root = result;
    }
}

pub fn rebalanceNode(self: *Self, node: *Node, scratch: std.mem.Allocator) struct { *Node, usize } {
    var list = std.ArrayList(*Node).empty;
    var iterator = self.nodeIterNode(node, scratch);
    while (iterator.next()) |current_node| {
        list.append(scratch, current_node) catch @panic("OOM");
    }
    const non_leafs = node.getNonLeafs(scratch);

    var non_leafs_slice: []const *Node = non_leafs.items;
    const result, const len = self.rebalanceImpl(&non_leafs_slice, list.items);
    std.debug.assert(non_leafs_slice.len == 0); // I'm not sure if this is true, so if it breaks we know it's not

    return .{ result, len };
}

/// reuse_non_leafs is a pool of nodes to be reused before allocating new nodes
/// nodes is the list of leafs nodes to rebuild
pub fn rebalanceImpl(self: *Self, reuse_non_leafs: *[]const *Node, nodes: []const *Node) struct { *Node, usize } {
    const result = switch (nodes.len) {
        1 => .{ nodes[0], nodes[0].total_length },
        2 => .{
            if (reuse_non_leafs.len != 0) node_blk: {
                defer reuse_non_leafs.len -= 1;
                break :node_blk reuse_non_leafs.*[reuse_non_leafs.len - 1].init(nodes[0], nodes[1]);
            } else self.createNode(nodes[0], nodes[1]),
            nodes[0].total_length,
        },
        else => blk: {
            const left, const left_len = self.rebalanceImpl(reuse_non_leafs, nodes[0 .. nodes.len / 2]);
            const right, const right_len = self.rebalanceImpl(reuse_non_leafs, nodes[nodes.len / 2 ..]);

            const result = if (reuse_non_leafs.len != 0) node_blk: {
                defer reuse_non_leafs.len -= 1;
                break :node_blk reuse_non_leafs.*[reuse_non_leafs.len - 1].init(left, right);
            } else self.createNode(left, right);
            result.total_length = left_len;

            break :blk .{ result, left_len + right_len };
        },
    };

    std.debug.print("Rebalance {}\n", .{result[1]});
    return result;
}

pub fn split(self: *Self, node: *Node, index: usize) struct { *Node, *Node } {
    if (node.isLeaf()) {
        switch (node.string) {
            .allocated => |list| {
                // We reuse the the current node's allocated for the lhs, and create a new allocated for rhs
                var allocated_list = std.ArrayList(u8).empty;
                allocated_list.appendSlice(self.allocator, list.items[index..]) catch @panic("OOM");

                const new_right = self.createLeafNode(.{ .allocated = allocated_list });
                node.string.allocated.items.len = index;
                node.total_length = index;
                return .{ node, new_right };
            },
            .read_only => |slice| {
                const new_right = self.createLeafNode(.{ .read_only = slice[index..] });
                node.string = .{ .read_only = slice[0..index] };
                node.total_length = index;
                return .{ node, new_right };
            },
        }
    }

    const midpoint = if (node.left) |left| left.total_length else 0;

    if (index < midpoint) {
        const new_left, const new_right = self.split(node.left.?, index);
        const right = self.createNode(new_right, node.right);

        return .{ new_left, right };
    } else if (index > midpoint) {
        const new_left, const new_right = self.split(node.right.?, index - midpoint);
        const left = self.createNode(node.left, new_left);

        return .{ left, new_right };
    } else {
        return .{ node.left.?, node.right.? };
    }
}

/// Inserts the given string at the given index.
/// String is copied, and an allocated node is inserted.
///
/// The root node must not be empty.
pub fn insertString(self: *Self, index: usize, string: []const u8) void {
    std.debug.assert(self.root != null);
    const current = self.root.?;

    var allocated_list = std.ArrayList(u8).empty;
    allocated_list.appendSlice(self.allocator, string) catch @panic("OOM");

    const allocated_string = Node.String{ .allocated = allocated_list };

    defer self.len += string.len;
    if (index == 0) {
        return self.prependString(allocated_string);
    } else if (index == self.len) {
        return self.appendString(allocated_string);
    }

    var lhs, var rhs = self.split(current, index);
    if (self.balance_state % 2 == 0) {
        lhs = self.createNode(lhs, self.createLeafNode(allocated_string));
    } else {
        rhs = self.createNode(self.createLeafNode(allocated_string), rhs);
    }
    self.balance_state += 1;
    self.root = self.createNode(lhs, rhs);
}

fn prependString(self: *Self, string: Node.String) void {
    var current = self.root;
    var parent: ?*Node = null;
    while (current != null and !current.?.isLeaf()) {
        parent = current;
        current.?.total_length += string.len();
        current = current.?.left;
    }

    const new_left = self.createLeafNode(string);
    if (parent) |p| {
        if (p.left) |left| {
            const new_parent = self.createNode(new_left, left);
            p.left = new_parent;
        } else {
            p.left = new_left;
        }
    } else {
        std.debug.assert(current != null);
        const new_parent = self.createNode(new_left, current.?);
        self.root = new_parent;
    }
}

fn appendString(self: *Self, string: Node.String) void {
    var current = self.root;
    var parent: ?*Node = null;
    while (current != null and !current.?.isLeaf()) {
        parent = current;
        current = current.?.right;
    }

    const new_right = self.createLeafNode(string);
    if (parent) |p| {
        if (p.right) |right| {
            const new_parent = self.createNode(right, new_right);
            p.right = new_parent;
        } else {
            p.right = new_right;
        }
    } else {
        std.debug.assert(current != null);
        const new_parent = self.createNode(current.?, new_right);
        self.root = new_parent;
    }
}

pub fn dumpNodeToFile(self: *Self, node: *Node, filename: []const u8) !void {
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});

    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io.io(), filename, .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io.io(), &buffer);

    try writer.interface.print("digraph {{\n", .{});
    _ = try self.dumpGraphImpl(node, 0, &writer.interface);
    try writer.interface.print("}}\n", .{});

    try writer.interface.flush();
    file.close(io.io());
}

pub fn dumpGraph(self: *Self, writer: *std.Io.Writer) !void {
    try writer.print("digraph {{\n", .{});
    _ = try self.dumpGraphImpl(self.root.?, 0, writer);
    try writer.print("}}\n", .{});
}

pub fn dumpGraphImpl(self: *Self, node: *Node, id: usize, writer: *std.Io.Writer) !usize {
    const my_id = id;
    if (node.isLeaf()) {
        try writer.print("node{} [label=\"{}\\n{s}\"];\n", .{ my_id, node.total_length, node.string.items() });

        return id + 1;
    } else {
        var next_id = id;

        try writer.print("node{} [label=\"{}\"];\n", .{ my_id, node.total_length });

        if (node.left) |left| {
            next_id = try self.dumpGraphImpl(left, id + 1, writer);
            try writer.print("node{} -> node{}\n", .{ my_id, id + 1 });
        }
        if (node.right) |right| {
            const this_id = next_id;
            next_id = try self.dumpGraphImpl(right, this_id, writer);
            try writer.print("node{} -> node{}\n", .{ my_id, this_id });
        }

        return next_id;
    }
}

// pub fn rebalanace()

pub const Iterator = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(*Node),
    index: usize = 0,

    pub fn next(self: *Iterator) ?u32 {
        const current = self.stack.getLastOrNull() orelse return null;

        if (self.index >= current.string.len()) {
            var left = self.stack.pop() orelse return null;

            if (self.stack.pop()) |parent| {
                if (parent.right) |right| {
                    self.stack.append(self.allocator, right) catch @panic("OOM");

                    var next_left = right.left;
                    left = right;
                    while (next_left != null) {
                        self.stack.append(self.allocator, next_left.?) catch @panic("OOM");
                        left = next_left.?;
                        next_left = next_left.?.left;
                    }
                }
            } else return null;

            const length = std.unicode.utf8ByteSequenceLength(left.string.items()[0]) catch @panic("invalid utf8");
            const codepoint = std.unicode.utf8Decode(left.string.items()[0..length]) catch @panic("invalid utf8");
            defer self.index = length;

            return @as(u32, codepoint);
        } else {
            const length = std.unicode.utf8ByteSequenceLength(current.string.items()[self.index]) catch @panic("invlaid utf8");
            const codepoint = std.unicode.utf8Decode(current.string.items()[self.index .. self.index + length]) catch @panic("invalid utf8");
            defer self.index += length;

            return @as(u32, codepoint);
        }
    }

    pub fn deinit(self: *Iterator) void {
        self.stack.deinit(self.allocator);
    }
};

pub inline fn iter(self: *Self, allocator: std.mem.Allocator) Iterator {
    return self.iterNode(self.root, allocator);
}

pub fn iterNode(self: *Self, node: ?*Node, allocator: std.mem.Allocator) Iterator {
    _ = self;
    var current = node;

    var stack = std.ArrayList(*Node).empty;
    while (current != null) {
        stack.append(allocator, current.?) catch @panic("OOM");
        current = current.?.left;
    }

    return .{ .allocator = allocator, .stack = stack };
}

pub const NodeIterator = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(*Node),

    pub fn next(self: *NodeIterator) ?*Node {
        const left = self.stack.pop() orelse return null;

        if (self.stack.pop()) |parent| {
            if (parent.right) |right| {
                self.stack.append(self.allocator, right) catch @panic("OOM");

                var next_left = right.left;
                while (next_left != null) {
                    self.stack.append(self.allocator, next_left.?) catch @panic("OOM");
                    next_left = next_left.?.left;
                }
            }
        }
        return left;
    }

    pub fn deinit(self: *NodeIterator) void {
        self.stack.deinit(self.allocator);
    }
};

pub inline fn nodeIter(self: *Self, allocator: std.mem.Allocator) NodeIterator {
    return self.nodeIterNode(self.root, allocator);
}

pub fn nodeIterNode(self: *Self, node: ?*Node, allocator: std.mem.Allocator) NodeIterator {
    _ = self;
    var current = node;

    var stack = std.ArrayList(*Node).empty;
    while (current != null) {
        stack.append(allocator, current.?) catch @panic("OOM");
        current = current.?.left;
    }

    return .{ .allocator = allocator, .stack = stack };
}

test "rope test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();

    var rope = Self.init(arena.allocator());
    rope.loadString("what the hell are you doing");
    rope.insertString(7, "1234", scratch.allocator());
    rope.insertString(15, "bruhv", scratch.allocator());

    std.debug.print("ffooba\n", .{});
    var i = rope.iter(std.testing.allocator);
    while (i.next()) |f| {
        std.debug.print("char: {u}\n", .{@as(u21, @truncate(f))});
    }
    i.deinit();

    // var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), std.testing.io, "output.dot", .{});
    // var buffer: [4096]u8 = undefined;
    // var writer = file.writer(std.testing.io, &buffer);

    // try rope.dumpGraph(&writer.interface);
    // try writer.flush();
    // file.close(std.testing.io);
}
