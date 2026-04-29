const std = @import("std");
const builtin = @import("builtin");
pub const Self = @This();

pub const Node = struct {
    str: []const u8,
    weight: usize,
    left: ?*Node = null,
    right: ?*Node = null,

    pub inline fn isLeaf(self: *const Node) bool {
        if (builtin.mode == .Debug) {
            if (self.str.len == 0)
                std.debug.assert(self.left != null or self.right != null)
            else
                std.debug.assert(self.left == null and self.right == null);
        }
        return self.str.len != 0;
    }
};

allocator: std.mem.Allocator,
node_pool: std.heap.MemoryPool(Node),
root: ?*Node,
len: usize = 0,

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
        .str = &.{},
        .weight = 0,
    };
    self.root = node;
    self.len = 0;
}

pub fn loadString(self: *Self, str: []const u8) void {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .str = str,
        .weight = str.len,
    };
    self.root = node;
    self.len = str.len;
}

pub fn createNode(self: *Self, left: ?*Node, right: ?*Node) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .str = "",
        .weight = if (left) |l| l.weight else 0,
        .left = left,
        .right = right,
    };
    return node;
}

pub fn createLeafNode(self: *Self, string: []const u8) *Node {
    const node = self.node_pool.create(self.allocator) catch @panic("OOM");
    node.* = .{
        .str = string,
        .weight = string.len,
    };
    return node;
}

// pub fn insert(self: *Self, index: usize, codepoint: u32) void {

// }

pub fn rebalance(self: *Self, node: *Node, scratch: std.mem.Allocator) struct { *Node, usize } {
    var list = std.ArrayList(*Node).empty;
    var iterator = self.nodeIterNode(node, scratch);
    while (iterator.next()) |current_node| {
        list.append(scratch, current_node) catch @panic("OOM");
    }
    const result, const len = self.rebalanceImpl(list.items);
    return .{ result, len };
}

pub fn rebalanceImpl(self: *Self, nodes: []const *Node) struct { *Node, usize } {
    const result = switch (nodes.len) {
        1 => .{ nodes[0], nodes[0].weight },
        2 => .{ self.createNode(nodes[0], nodes[1]), nodes[0].weight },
        else => blk: {
            const left, const left_len = self.rebalanceImpl(nodes[0 .. nodes.len / 2]);
            const right, const right_len = self.rebalanceImpl(nodes[nodes.len / 2 ..]);

            const result = self.createNode(left, right);
            result.weight = left_len;

            break :blk .{ result, left_len + right_len };
        },
    };

    std.debug.print("Rebalance {}\n", .{result[1]});
    return result;
}

pub fn split(self: *Self, node: *Node, index: usize, scratch: std.mem.Allocator) struct { *Node, *Node, usize } {
    if (node.isLeaf()) {
        const new_right = self.createLeafNode(node.str[index..]);
        node.str = node.str[0..index];
        node.weight = index;
        return .{ node, new_right, node.str.len };
    }

    if (index < node.weight) {
        const new_left, const new_right, _ = self.split(node.left.?, index, scratch);
        const left_balanced, const left_len = self.rebalance(new_left, scratch);
        const right_balanced, _ = self.rebalance(self.createNode(new_right, node.right), scratch);

        return .{ left_balanced, right_balanced, left_len };
    } else if (index > node.weight) {
        const new_left, const new_right, _ = self.split(node.right.?, index - node.weight, scratch);
        const left_balanced, const left_len = self.rebalance(self.createNode(node.left, new_left), scratch);
        const right_balanced, _ = self.rebalance(new_right, scratch);

        return .{ left_balanced, right_balanced, left_len };
    } else {
        @panic("jflkdsjf");
        // return .{ node.left.?, node.right.?, if (node.left) |left|  };
    }
}

pub fn insertString(self: *Self, index: usize, string: []const u8, scratch: std.mem.Allocator) void {
    const current = self.root orelse {
        self.loadString(string);
        return;
    };

    defer self.len += string.len;
    if (index == 0) {
        return self.prependString(string);
    } else if (index == self.len) {
        return self.appendString(string);
    }

    var lhs, const rhs, const len = self.split(current, index, scratch);

    const root_len = lhs.weight + string.len;
    lhs = self.createNode(lhs, self.createLeafNode(string));
    lhs.weight = len;

    self.root = self.createNode(lhs, rhs);
    self.root.?.weight = root_len;
}

fn prependString(self: *Self, string: []const u8) void {
    var current = self.root;
    var parent: ?*Node = null;
    while (current != null and !current.?.isLeaf()) {
        parent = current;
        current.?.weight += string.len;
        current = current.?.left;
    }

    const new_left = self.createLeafNode(string);
    if (parent) |p| {
        // const left_len = current.?.str.len;

        // Rebalance
        // current = self.root;
        // while (current != null and !current.?.isLeaf()) {
        //     current.?.weight = current.?.weight - left_len + string.len;
        //     current = current.?.left;
        // }

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

fn appendString(self: *Self, string: []const u8) void {
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
        try writer.print("node{} [label=\"{}\\n{s}\"];\n", .{ my_id, node.weight, node.str });

        return id + 1;
    } else {
        var next_id = id;

        try writer.print("node{} [label=\"{}\"];\n", .{ my_id, node.weight });

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

        if (self.index >= current.str.len) {
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

            const length = std.unicode.utf8ByteSequenceLength(left.str[0]) catch @panic("invalid utf8");
            const codepoint = std.unicode.utf8Decode(left.str[0..length]) catch @panic("invalid utf8");
            defer self.index = length;

            return @as(u32, codepoint);
        } else {
            const length = std.unicode.utf8ByteSequenceLength(current.str[self.index]) catch @panic("invlaid utf8");
            const codepoint = std.unicode.utf8Decode(current.str[self.index .. self.index + length]) catch @panic("invalid utf8");
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
        var left = self.stack.pop() orelse return null;

        if (self.stack.pop()) |parent| {
            if (parent.right) |right| {
                self.stack.append(self.allocator, right) catch @panic("OOM");

                var next_left = right.left;
                while (next_left != null) {
                    self.stack.append(self.allocator, next_left.?) catch @panic("OOM");
                    left = next_left.?;
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
