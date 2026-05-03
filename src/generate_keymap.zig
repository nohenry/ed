const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next() orelse return error.ExpectedOutputFile;
    const output_file = args.next() orelse return error.ExpectedOutputFile;

    const file = try std.Io.Dir.cwd().createFile(init.io, output_file, .{});
    defer file.close(init.io);

    var writer = file.writer(init.io, &.{});

    try generate(&writer.interface, @import("keymap_definition.zig").keymap_definition);
}

const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;

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
};

pub fn movementKeys(movement_: Movement) u8 {
    return switch (movement_) {
        .left => 'h',
        .right => 'l',
        .up => 'k',
        .down => 'j',
        .word_forward => 'w',
        .word_backward => 'b',
        .word_end_forward => 'e',
    };
}

const KeyNode = struct {
    leaf: ?[]const u8 = null,
    leaf_movement: ?Movement = null,
    keys: std.AutoHashMapUnmanaged(KeyCombo, *KeyNode) = .empty,
    state: usize = 0,
};

fn generate(writer: *std.Io.Writer, comptime keymap: anytype) !void {
    var root = KeyNode{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    inline for (keymap) |command| {
        var current = &root;

        var done_movement = false;
        inline for (command, 0..) |item, i| {
            if (i == command.len - 1) {
                if (done_movement) {
                    inline for (std.meta.fields(Movement)) |field| {
                        current.keys.get(.{ .char = @truncate(movementKeys(@enumFromInt(field.value))) }).?.leaf = @as([]const u8, item);
                    }
                } else {
                    current.leaf = item;
                }
            } else {
                if (@TypeOf(item) == comptime_int or @TypeOf(item) == u32) {
                    if (item == movement) {
                        inline for (std.meta.fields(Movement)) |field| {
                            const result = try current.keys.getOrPut(allocator, .{ .char = @truncate(movementKeys(@enumFromInt(field.value))) });
                            if (!result.found_existing) {
                                const new_node = try allocator.create(KeyNode);
                                new_node.* = .{
                                    .leaf_movement = @enumFromInt(field.value),
                                };
                                result.value_ptr.* = new_node;
                            }
                        }
                        done_movement = true;
                    } else {
                        const result = try current.keys.getOrPut(allocator, .{ .char = @truncate(item) });
                        if (!result.found_existing) {
                            const new_node = try allocator.create(KeyNode);
                            new_node.* = .{};
                            result.value_ptr.* = new_node;
                        }
                        current = result.value_ptr.*;
                    }
                } else if (@typeInfo(@TypeOf(item)) == .@"struct") {
                    const new_node = try allocator.create(KeyNode);
                    new_node.* = .{};
                    var key = KeyCombo{ .char = 0 };

                    inline for (item) |sub_key| {
                        switch (sub_key) {
                            ctrl => key.ctrl = 1,
                            shift => key.shift = 1,
                            alt => key.alt = 1,
                            else => key.char = @truncate(sub_key),
                        }
                    }
                    try current.keys.put(allocator, key, new_node);

                    current = new_node;
                } else @compileError(std.fmt.comptimePrint("invalid type: {}", .{@TypeOf(item)}));
            }
        }
    }

    var state_var: usize = 1;
    _ = try writer.write("pub const DispatchResult = enum { not_mapped, waiting, dispatched_command };\n");
    _ = try writer.write("pub const KeyMovement = struct { cursor_position: usize = 0, max_column: usize = 0 };\n");
    _ = try writer.write("pub const DispatchState = struct { state: usize = 0, key_movement: KeyMovement = .{} };\n");
    _ = try writer.write("pub fn dispatchCommand(state: *DispatchState, key: u16, command_handlers: anytype) DispatchResult {\n");

    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("switch (state.state) {\n");

    try generate_zig_code(writer, &root, &state_var, 2);

    for (0..2) |_| _ = try writer.write("    ");
    _ = try writer.write("else => unreachable,\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("}\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("state.state = 0;\n");
    for (0..1) |_| _ = try writer.write("    ");
    _ = try writer.write("return .dispatched_command;\n");

    _ = try writer.write("}\n");
}

fn generate_zig_code(writer: *std.Io.Writer, node: *KeyNode, state_var: *usize, i: usize) !void {
    if (node.leaf != null) {
        for (0..i) |_| _ = try writer.write("    ");
        try writer.print("{s}();\n", .{node.leaf.?});
        return;
    }

    for (0..i) |_| _ = try writer.write("    ");
    try writer.print("{} => switch (key) {{\n", .{node.state});

    var iter = node.keys.iterator();
    while (iter.next()) |entry| {
        for (0..i + 1) |_| _ = try writer.write("    ");
        const k = entry.key_ptr.*;
        if (k.ctrl > 0 or k.shift > 0 or k.alt > 0) {
            try writer.print("0b{}{}{}0000000 | ", .{ k.alt, k.shift, k.ctrl });
        }
        try writer.print("'{c}' => ", .{@as(u8, k.char)});

        if (entry.value_ptr.*.leaf) |leaf| {
            if (entry.value_ptr.*.leaf_movement) |movement_| {
                try writer.print("command_handlers.{s}(.{t}),\n", .{ leaf, movement_ });
            } else {
                try writer.print("command_handlers.{s}(null),\n", .{leaf});
            }
        } else {
            const this_state = state_var.*;
            try writer.print("{{ state.state = {}; return .waiting; }},\n", .{this_state});

            entry.value_ptr.*.state = this_state;
            state_var.* += 1;
        }
    }

    for (0..i + 1) |_| _ = try writer.write("    ");
    _ = try writer.write("else => return .not_mapped,\n");
    for (0..i) |_| _ = try writer.write("    ");
    _ = try writer.write("},\n");

    iter = node.keys.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.*.leaf == null and entry.value_ptr.*.leaf_movement == null) {
            try generate_zig_code(writer, entry.value_ptr.*, state_var, i);
        }
    }
}
