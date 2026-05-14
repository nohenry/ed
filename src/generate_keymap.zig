const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next() orelse return error.ExpectedOutputFile;
    const output_file = args.next() orelse return error.ExpectedOutputFile;

    const file = try std.Io.Dir.cwd().createFile(init.io, output_file, .{});
    defer file.close(init.io);

    var writer = file.writer(init.io, &.{});

    _ = try writer.interface.write("pub const DispatchResult = enum { not_mapped, waiting, dispatched_command };\n");
    _ = try writer.interface.write("pub fn DispatchState(comptime Movement: type) type { return struct { state: usize = 0, characters: [4]u32 = [4]u32{0,0,0,0}, character_count: usize = 0, movement: ?Movement = null, pub fn chars(self: *const @This()) []const u32 { return self.characters[0..self.character_count]; } }; }\n");

    try generate(&writer.interface, "dispatchLineInputCommand", @import("keymap_definition.zig").line_input_keymap_definition);
    try generate(&writer.interface, "dispatchNormalCommand", @import("keymap_definition.zig").normal_keymap_definition);
    try generate(&writer.interface, "dispatchVisualCommand", @import("keymap_definition.zig").visual_keymap_definition);
}

const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;
const character: u32 = 500000;

const KeyCombo = packed struct(u16) {
    char: u7,
    ctrl: u1 = 0,
    shift: u1 = 0,
    alt: u1 = 0,
    _: u6 = 0,
};

const Movement = enum {
    left,
    right,
    up,
    down,
    word_forward,
    word_backward,
    word_end_forward,
    start_of_line,
    start_of_line_non_blank,
    end_of_line,

    find_next,
    find_prev,
    find_till_next,
    find_till_prev,
    find_again_next,
    find_again_prev,

    text_object_inner,
    text_object_outer,
};

pub fn movementTupleToCombo(movement_tuple: anytype) KeyCombo {
    var key = KeyCombo{ .char = 0 };

    inline for (movement_tuple) |sub_key| {
        switch (sub_key) {
            ctrl => key.ctrl = 1,
            shift => key.shift = 1,
            alt => key.alt = 1,
            else => key.char = @truncate(sub_key),
        }
    }

    return key;
}

pub fn movementExcludeFromTopLevel(comptime movement_: Movement) bool {
    return switch (movement_) {
        .text_object_inner, .text_object_outer => true,
        else => false,
    };
}

pub fn movementKeysCombo(comptime movement_: Movement) KeyCombo {
    const value = switch (movement_) {
        .left => .{'h'},
        .right => .{'l'},
        .up => .{'k'},
        .down => .{'j'},
        .word_forward => .{'w'},
        .word_backward => .{'b'},
        .word_end_forward => .{'e'},
        .start_of_line => .{'0'},
        .start_of_line_non_blank => .{'_'},
        .end_of_line => .{'$'},

        .find_next => .{'f'},
        .find_prev => .{'F'},
        .find_till_next => .{'t'},
        .find_till_prev => .{'T'},
        .find_again_next => .{';'},
        .find_again_prev => .{','},

        .text_object_inner => .{'i'},
        .text_object_outer => .{'a'},
    };
    return movementTupleToCombo(value);
}

pub fn movementKeysNeedsChar(comptime movement_: Movement) bool {
    return switch (movement_) {
        .find_next,
        .find_prev,
        .find_till_next,
        .find_till_prev,
        .text_object_inner,
        .text_object_outer,
        => true,
        else => false,
    };
}

// Node(root) -> Node('d') -> Node(movement 'f') -> Node(character)
//  children      children     movement              character

// Node(root) -> Node('d') -> Node(movement 'f') -> Node('f')
//  children      children     movement              character

const KeyComboMap = std.AutoHashMapUnmanaged(KeyCombo, *KeyNode1);

const KeyNode1 = struct {
    state: usize = 0,
    movement: ?Movement = null,
    next: union(enum) {
        invalid,
        leaf: []const u8,
        character: ?*KeyNode1,
        children: KeyComboMap,
    },
    generated: bool = false,

    pub fn format(self: *const KeyNode1, w: *std.Io.Writer) !void {
        try self.formatImpl(w, 0);
    }

    pub fn formatImpl(self: *const KeyNode1, w: *std.Io.Writer, indent: usize) !void {
        for (0..indent) |_| _ = try w.writeAll("   ");

        if (self.movement) |m| try w.print("Has movement: {}  ", .{m});

        switch (self.next) {
            .invalid => try w.print("Node Invalid\n", .{}),
            .leaf => |l| try w.print("Node Leaf '{s}' {*}\n", .{ l, self }),
            .character => |c| {
                try w.print("Node Character {} {*}\n", .{ self.state, self });
                if (c) |sc| try sc.formatImpl(w, indent + 1);
            },
            .children => |c| {
                var iter = c.iterator();
                try w.print("Node Children: {} {*}\n", .{ self.state, self });
                while (iter.next()) |entry| {
                    for (0..indent + 1) |_| _ = try w.writeAll("   ");

                    try w.print("'{c}' => \n", .{entry.key_ptr.char});
                    try entry.value_ptr.*.formatImpl(w, indent + 2);
                }
            },
        }
    }
};

fn generate(writer: *std.Io.Writer, dispatch_function_name: []const u8, comptime keymap: anytype) !void {
    var root = KeyNode1{ .next = .{ .children = .empty } };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    var next_state: usize = 1;

    var nodes = std.ArrayList(*KeyNode1).empty;
    inline for (keymap) |command| {
        nodes.items.len = 0;
        nodes.append(allocator, &root) catch @panic("OOM");

        inline for (command, 0..) |item, i| {
            if (i == command.len - 1) {
                for (nodes.items) |parent_node| {
                    switch (parent_node.next) {
                        .invalid => {
                            parent_node.next = .{ .leaf = item };
                        },
                        .character => |ch| {
                            ch.?.next = .{ .leaf = item };
                        },
                        .children => |ch| {
                            var iter = ch.iterator();
                            while (iter.next()) |entry| {
                                entry.value_ptr.*.next = .{ .leaf = item };
                            }
                        },
                        .leaf => {},
                    }
                }
            } else {
                if (@TypeOf(item) == comptime_int or @TypeOf(item) == u32) {
                    if (item == movement) {
                        const these_nodes = nodes.toOwnedSlice(allocator) catch @panic("OOM");
                        defer allocator.free(these_nodes);
                        nodes.ensureTotalCapacity(allocator, these_nodes.len * std.meta.fields(Movement).len) catch @panic("OOM");
                        nodes.items.len = 0;

                        const char_node_state = next_state;
                        const char_node = try allocator.create(KeyNode1);
                        char_node.* = .{ .state = char_node_state, .next = .invalid };
                        next_state += 1;

                        for (these_nodes) |parent_node| {
                            const movement_state = next_state;
                            next_state += 1;

                            inline for (std.meta.fields(Movement)) |field| {
                                const movement_ = comptime movementKeysCombo(@enumFromInt(field.value));
                                if (i == 0 and comptime movementExcludeFromTopLevel(@enumFromInt(field.value))) continue;
                                const needs_char = movementKeysNeedsChar(@enumFromInt(field.value));

                                const result = switch (parent_node.next) {
                                    .invalid => blk: {
                                        parent_node.next = .{ .children = .empty };
                                        break :blk try parent_node.next.children.getOrPut(allocator, movement_);
                                    },
                                    .character => |*map| KeyComboMap.GetOrPutResult{ .found_existing = map.* != null, .value_ptr = &(map.*.?), .key_ptr = undefined },
                                    .children => |*map| try map.getOrPut(allocator, movement_),
                                    .leaf => unreachable,
                                };

                                if (!result.found_existing) {
                                    const new_node = try allocator.create(KeyNode1);
                                    new_node.* = .{ .state = movement_state, .movement = @enumFromInt(field.value), .next = if (needs_char) .{ .character = char_node } else .invalid };
                                    result.value_ptr.* = new_node;
                                }

                                if (needs_char) {} else {
                                    nodes.append(allocator, result.value_ptr.*) catch @panic("OOM");
                                }
                            }
                        }

                        nodes.append(allocator, char_node) catch @panic("OOM");
                    } else if (item == character) {
                        for (nodes.items) |*parent_node| {
                            const result = switch (parent_node.*.next) {
                                .invalid => blk: {
                                    parent_node.*.next = .{ .character = @as(*KeyNode1, undefined) };
                                    break :blk KeyComboMap.GetOrPutResult{ .found_existing = false, .value_ptr = &(parent_node.*.next.character.?), .key_ptr = undefined };
                                },
                                .character => |*map| KeyComboMap.GetOrPutResult{ .found_existing = map.* != null, .value_ptr = &(map.*.?), .key_ptr = undefined },
                                .children => |*ch| {
                                    const new_node = try allocator.create(KeyNode1);
                                    new_node.* = .{ .state = next_state, .next = .invalid };
                                    next_state += 1;

                                    var iter = ch.iterator();
                                    while (iter.next()) |entry| {
                                        entry.value_ptr.*.next = .{ .character = new_node };
                                    }

                                    parent_node.* = new_node;

                                    continue;
                                },
                                .leaf => unreachable,
                            };

                            if (!result.found_existing) {
                                const new_node = try allocator.create(KeyNode1);
                                new_node.* = .{ .state = next_state, .next = .invalid };
                                next_state += 1;
                                result.value_ptr.* = new_node;
                            }

                            parent_node.* = result.value_ptr.*;
                        }
                    } else {
                        for (nodes.items) |*parent_node| {
                            const result = switch (parent_node.*.next) {
                                .invalid => blk: {
                                    parent_node.*.next = .{ .children = .empty };
                                    break :blk try parent_node.*.next.children.getOrPut(allocator, .{ .char = @truncate(item) });
                                },
                                .character => |*map| KeyComboMap.GetOrPutResult{ .found_existing = map.* != null, .value_ptr = &(map.*.?), .key_ptr = undefined },
                                .children => |*map| try map.getOrPut(allocator, .{ .char = @truncate(item) }),
                                .leaf => unreachable,
                            };

                            if (!result.found_existing) {
                                const new_node = try allocator.create(KeyNode1);
                                new_node.* = .{ .state = next_state, .next = .invalid };
                                next_state += 1;
                                result.value_ptr.* = new_node;
                            }

                            parent_node.* = result.value_ptr.*;
                        }
                    }
                } else if (@typeInfo(@TypeOf(item)) == .@"struct") {
                    for (nodes.items) |*parent_node| {
                        const new_node = try allocator.create(KeyNode1);
                        new_node.* = .{ .next = .invalid };

                        switch (parent_node.*.next) {
                            .invalid => {
                                parent_node.*.next = .{ .children = .empty };
                                try parent_node.*.next.children.put(allocator, movementTupleToCombo(item), new_node);
                            },
                            .character => {},
                            .children => |*map| try map.put(allocator, movementTupleToCombo(item), new_node),
                            .leaf => unreachable,
                        }

                        parent_node.* = new_node;
                    }
                } else @compileError(std.fmt.comptimePrint("invalid type: {}", .{@TypeOf(item)}));
            }
        }
    }

    std.debug.print("{f}\n", .{root});

    try writer.print("pub fn {s}(state: anytype, key: u16, command_handlers: anytype) DispatchResult {{\n", .{dispatch_function_name});

    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("switch (state.state) {\n");

    try generate_zig_code(writer, &root, 2);

    for (0..2) |_| _ = try writer.write("    ");
    _ = try writer.write("else => unreachable,\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("}\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("state.state = 0;\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("state.character_count = 0;\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("state.movement = null;\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("return .dispatched_command;\n");

    _ = try writer.write("}\n");
}

fn generate_zig_code(writer: *std.Io.Writer, node: *KeyNode1, i: usize) !void {
    if (node.generated) return;
    node.generated = true;

    switch (node.next) {
        .character => |value| if (value != null and value.?.generated) return,
        else => {},
    }

    for (0..i) |_| _ = try writer.write("    ");
    try writer.print("{} => ", .{node.state});

    switch (node.next) {
        .invalid => unreachable,
        .leaf => |value| try writer.print("command_handlers.{s}(state),\n", .{value}),
        .character => |value| {
            if (value.?.next == .leaf) {
                value.?.generated = true;
                try writer.print("{{ state.characters[state.character_count] = key; state.character_count += 1; command_handlers.{s}(state); }},\n", .{value.?.next.leaf});
            } else {
                try writer.print("{{ state.characters[state.character_count] = key; state.character_count += 1; state.state = {}; return .waiting; }},\n", .{value.?.state});
            }
        },

        .children => |value| {
            try writer.print("switch (key) {{\n", .{});

            var iter = value.iterator();
            while (iter.next()) |entry| {
                for (0..i + 1) |_| _ = try writer.write("    ");
                const k = entry.key_ptr.*;
                if (k.ctrl > 0 or k.shift > 0 or k.alt > 0) {
                    try writer.print("0b{}{}{}0000000 | ", .{ k.alt, k.shift, k.ctrl });
                }

                if (entry.value_ptr.*.movement) |move| {
                    if (entry.value_ptr.*.next == .leaf) {
                        entry.value_ptr.*.generated = true;
                        try writer.print("'{c}' => {{ state.movement = .{t}; command_handlers.{s}(state); }},\n", .{ @as(u8, k.char), move, entry.value_ptr.*.next.leaf });
                    } else {
                        try writer.print("'{c}' => {{ state.movement = .{t}; state.state = {}; return .waiting; }},\n", .{ @as(u8, k.char), move, entry.value_ptr.*.state });
                    }
                } else {
                    if (entry.value_ptr.*.next == .leaf) {
                        entry.value_ptr.*.generated = true;
                        try writer.print("'{c}' => command_handlers.{s}(state),\n", .{ @as(u8, k.char), entry.value_ptr.*.next.leaf });
                    } else {
                        try writer.print("'{c}' => {{ state.state = {}; return .waiting; }},\n", .{ @as(u8, k.char), entry.value_ptr.*.state });
                    }
                }
            }

            for (0..i + 1) |_| _ = try writer.write("    ");
            _ = try writer.write("else => return .not_mapped,\n");

            for (0..i) |_| _ = try writer.write("    ");
            try writer.print("}},\n", .{});
        },
    }

    switch (node.next) {
        .invalid => unreachable,
        .leaf => {},
        .character => |value| {
            try generate_zig_code(writer, value.?, i);
        },
        .children => |value| {
            var iter = value.iterator();
            while (iter.next()) |entry| {
                try generate_zig_code(writer, entry.value_ptr.*, i);
            }
        },
    }
}
