const std = @import("std");
const ed = @import("ed.zig");
const keymap = @import("keymap");

comptime {
    _ = keymap;
}

pub const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
documents: std.AutoHashMapUnmanaged(ed.Document.Id, ed.Document) = .empty,
next_document_id: ed.Document.Id = .{ .value = 1 },
current_document: ed.Document.Id = .nil,
view: ed.View = .{},

mode: enum {
    insert,
    normal,
} = .normal,

saved_insert_node: ?*ed.Rope.Node = null,

key_dispatch_state: keymap.DispatchState = .{},

pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
    return .{
        .io = io,
        .allocator = allocator,
    };
}

pub fn resize(self: *Self, lines: u32, columns: u32) void {
    self.view.lines = lines;
    self.view.columns = columns;
}

pub fn openDocument(self: *Self, path: []const u8) void {
    var next_id = self.next_document_id;
    while (self.documents.contains(next_id)) {
        next_id = next_id.increment();
    }

    const entry = self.documents.getOrPut(self.allocator, next_id) catch @panic("OOM");
    entry.value_ptr.load(self.io, path);
    self.current_document = next_id;
    self.next_document_id = next_id.increment();
}

pub fn handleEvent(self: *Self, event: ed.Event) void {
    switch (event) {
        .key_down => {
            switch (self.mode) {
                .insert => self.handleInsertModeKeydown(event),
                .normal => self.handleNormalModeKeydown(event),
            }
        },
    }
}

pub fn handleInsertModeKeydown(self: *Self, event: ed.Event) void {
    const document = self.documents.getPtr(self.current_document) orelse return;
    const data = event.key_down;
    switch (data.key) {
        .char => {
            const node = self.saved_insert_node orelse blk: {
                const new_node = document.rope.insertString(self.view.cursor_position, "");
                self.saved_insert_node = new_node;
                break :blk new_node;
            };

            var out: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(@truncate(data.char), &out) catch @panic("invlaid utf8");
            node.appendSlice(self.allocator, out[0..utf8_len]) catch @panic("OOM");
            self.view.cursor_position += utf8_len;
            self.view.max_column += utf8_len;
        },
        .escape => {
            self.mode = .normal;
            self.saved_insert_node = null;
            ed.Rope.dumpNodeToFile(document.rope.root.?, "out.dot") catch @panic("fjklsdjfsd");
        },
    }
}

pub fn handleNormalModeKeydown(self: *Self, event: ed.Event) void {
    const document = self.documents.getPtr(self.current_document) orelse return;
    // _ = document;
    const data = event.key_down;

    if (data.key == .char and (data.char & 0x7F) == data.char) {
        _ = keymap.dispatchCommand(&self.key_dispatch_state, (@as(u16, @as(u3, @bitCast(data.modifers))) << 7) | @as(u7, @truncate(data.char)), self);
    }
    ed.Rope.dumpNodeToFile(document.rope.root.?, "out.dot") catch @panic("fjklsdjfsd");
}

pub fn commandEnterInsertMode(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
}

pub fn commandDeleteMovement(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement(movement.?, .delete) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;
    _ = document.rope.deleteRange(movement_result.range_start, movement_result.range_end);

    if (movement_result.linewise) {
        self.view.cursor_position = movement_result.cursor_position;
    }
}

pub fn commandDeleteLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    _ = self;
    std.debug.print("Delte line\n", .{});
}

pub fn commandMoveUpHalfView(self: *Self, movement: ?Movement) void {
    _ = movement;

    const line_difference = self.view.lines / 2;
    var coords = self.calculateCursorViewCoords();
    coords.column = @truncate(self.view.max_column);

    const document = self.documents.getPtr(self.current_document) orelse return;
    const new_start_position = document.rope.sub(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = line_difference, .column = 0 },
        ed.Rope.Position,
    );

    self.view.start_position = new_start_position;

    if (new_start_position == 0) {
        coords.line -|= line_difference;
        self.view.cursor_position = document.rope.add(
            new_start_position,
            coords,
            ed.Rope.Position,
        );
    } else {
        self.view.cursor_position = document.rope.add(
            new_start_position,
            coords,
            ed.Rope.Position,
        );
    }
}

pub fn commandMoveDownHalfView(self: *Self, movement: ?Movement) void {
    _ = movement;

    const line_difference = self.view.lines / 2;
    var coords = self.calculateCursorViewCoords();
    coords.column = @truncate(self.view.max_column);

    const document = self.documents.getPtr(self.current_document) orelse return;
    const new_start_position = document.rope.add(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = line_difference, .column = 0 },
        ed.Rope.Position,
    );

    const max_pos = document.rope.sub(
        document.rope.len - 1,
        ed.Rope.Coordinate{ .line = self.view.lines - 1, .column = 0 },
        ed.Rope.Position,
    );
    self.view.start_position = @min(new_start_position, max_pos);

    self.view.cursor_position = document.rope.add(
        new_start_position,
        coords,
        ed.Rope.Position,
    );
}

pub fn commandMove(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement(movement.?, .move);
    if (movement_result) |move| {
        self.view.cursor_position = move.cursor_position;
        self.view.max_column = move.max_column;

        const document = self.documents.getPtr(self.current_document) orelse return;

        // Cursor going before the start of the view is less expensive to calculate, so we do it first
        if (self.view.cursor_position < self.view.start_position) {
            const line_range = document.rope.getLineRange(self.view.cursor_position) orelse .{ 0, 0 };
            self.view.start_position = line_range[0];
        } else {
            const coords = self.calculateCursorViewCoords();
            if (coords.line + 2 > self.view.lines) {
                const line_difference = coords.line + 2 - self.view.lines;
                const new_start_position = document.rope.add(
                    self.view.start_position,
                    ed.Rope.Coordinate{ .line = line_difference, .column = 0 },
                    ed.Rope.Position,
                );
                self.view.start_position = new_start_position;
            }
        }
    }
}

pub const Movement = enum {
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
};

pub const KeyMovement = struct {
    range_start: usize = 0,
    range_end: usize = 0,
    cursor_position: usize = 0,
    max_column: usize = 0,
    linewise: bool = false,
};

pub fn movementIsDefaultLinewise(movement: Movement) bool {
    return switch (movement) {
        .left => false,
        .right => false,
        .up => true,
        .down => true,
        .word_forward => false,
        .word_backward => false,
        .word_end_forward => false,
        .start_of_line => false,
        .start_of_line_non_blank => false,
        .end_of_line => false,
    };
}

pub fn calculateKeyMovement(self: *Self, movement: Movement, comptime purpose: enum { move, delete }) ?KeyMovement {
    const document = self.documents.getPtr(self.current_document) orelse return null;

    var result = KeyMovement{
        .range_start = self.view.cursor_position,
        .range_end = self.view.cursor_position,
        .cursor_position = self.view.cursor_position,
        .max_column = self.view.max_column,
        .linewise = movementIsDefaultLinewise(movement),
    };
    switch (movement) {
        .right => {
            var do_max = true;
            if (document.rope.indexNode(self.view.cursor_position)) |node_and_offset| {
                const char = node_and_offset[0].string.items[node_and_offset[1]];
                if (char == '\n') {
                    result.max_column = 0;
                    do_max = false;
                }
            }
            result.range_start = self.view.cursor_position;
            result.range_end = self.view.cursor_position + 1;
            result.cursor_position = self.view.cursor_position + 1;
            if (do_max) result.max_column = self.view.max_column + 1;
        },
        .left => {
            if (self.view.cursor_position > 0) {
                result.range_start = self.view.cursor_position - 1;
                result.range_end = self.view.cursor_position;
                result.cursor_position = self.view.cursor_position - 1;
                result.max_column = self.view.max_column -| 1;

                if (document.rope.indexNode(result.cursor_position)) |node_and_offset| {
                    const char = node_and_offset[0].string.items[node_and_offset[1]];
                    if (char == '\n') {
                        const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                        result.max_column = line_range[1] - line_range[0] - 1;
                    }
                }
            }
        },
        .up => {
            if (self.view.cursor_position > 0) {
                if (document.rope.getPreviousLineRange(self.view.cursor_position)) |last_line_range| {
                    switch (purpose) {
                        .move => {
                            result.cursor_position = @min(last_line_range[0] + self.view.max_column, last_line_range[1] -| 1);
                            result.range_start = result.cursor_position;
                            result.range_end = self.view.cursor_position;
                        },
                        .delete => {
                            const current_line_range = document.rope.getLineRange(self.view.cursor_position).?;
                            result.range_start = last_line_range[0];
                            result.range_end = current_line_range[1];

                            if (last_line_range[0] == 0) {
                                result.cursor_position = 0;
                            } else {
                                const after_line_range = document.rope.getLineRange(current_line_range[1]).?;
                                result.cursor_position = last_line_range[0] + @min(self.view.max_column, after_line_range[1] - after_line_range[0] - 1);
                                // result.cursor_position = @min(self.view.max_column, last_line_range[1] - last_line_range[0] - 1);
                                // result.cursor_position = last_line_range[0];
                            }
                        },
                    }
                }
            }
        },
        .down => {
            if (document.rope.getNextLineRange(self.view.cursor_position)) |next_line_range| {
                switch (purpose) {
                    .move => {
                        result.cursor_position = @min(next_line_range[0] + self.view.max_column, next_line_range[1] -| 1);
                        result.range_start = self.view.cursor_position;
                        result.range_end = result.cursor_position;
                    },
                    .delete => {
                        const current_line_range = document.rope.getLineRange(self.view.cursor_position).?;
                        result.range_start = current_line_range[0];
                        result.range_end = next_line_range[1];

                        const after_line_range = document.rope.getLineRange(next_line_range[1]).?;
                        result.cursor_position = current_line_range[0] + @min(self.view.max_column, after_line_range[1] - after_line_range[0] - 1);
                    },
                }
            }
        },
        .word_forward => {
            const offset = document.rope.getNextWord(self.view.cursor_position);
            result.cursor_position = self.view.cursor_position + offset;
            result.range_start = self.view.cursor_position;
            result.range_end = result.cursor_position;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_backward => {
            const offset = document.rope.getPreviousWord(self.view.cursor_position);
            result.cursor_position = self.view.cursor_position - offset;
            result.range_start = result.cursor_position;
            result.range_end = self.view.cursor_position;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_end_forward => {
            const offset = document.rope.getNextWordEnd(self.view.cursor_position);
            switch (purpose) {
                .move => {
                    result.cursor_position = self.view.cursor_position + offset;
                },
                .delete => {
                    result.cursor_position = self.view.cursor_position + offset + 1;
                },
            }
            result.range_start = self.view.cursor_position;
            result.range_end = result.cursor_position; // inclusive

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .start_of_line => {
            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.range_start = line_range[0];
            result.range_end = self.view.cursor_position;
            result.cursor_position = line_range[0];
            result.max_column = 0;
        },
        .start_of_line_non_blank => {
            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null

            var current_offset = line_range[0];
            var current_node, var current_node_offset = document.rope.indexNode(line_range[0]).?;

            while (current_offset < document.rope.len) : (current_offset += 1) {
                switch (current_node.string.items[current_node_offset]) {
                    ' ', '\t', '\r' => {},
                    else => break,
                }

                current_node, current_node_offset = document.rope.nextNodeChar(current_node, current_node_offset) orelse break;
            }

            result.cursor_position = current_offset;
            if (self.view.cursor_position > current_offset) {
                result.range_start = current_offset;
                result.range_end = self.view.cursor_position;
            } else {
                result.range_start = self.view.cursor_position;
                result.range_end = current_offset;
            }

            result.max_column = result.cursor_position - line_range[0];
        },
        .end_of_line => {
            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.range_start = self.view.cursor_position;
            result.range_end = line_range[1];
            result.max_column = 0;
        },
    }
    return result;
}

pub fn calculateCursorViewCoords(self: *Self) ed.Rope.Coordinate {
    const current_document = self.documents.getPtr(self.current_document).?;
    const result = current_document.rope.lineColumnFromRelativePosition(self.view.start_position, self.view.cursor_position).?;
    // const result = current_document.rope.add(self.view.cursor_position, 0, ed.Rope.Coordinate);
    return result;
}

pub fn render(self: *Self, area: ed.Rect, renderer: *ed.Renderer) void {
    var output_buffer: [2]u16 = undefined;
    if (self.current_document.isValid()) {
        const current_document = self.documents.getPtr(self.current_document).?;
        var text_iterator = current_document.rope.iterUtf16StartingFrom(&output_buffer, self.view.start_position);

        const bg_color_ = ed.Color.init(40, 40, 60);
        var current_char_offset: usize = 0;

        var x: u16 = @truncate(area.left);
        var y: u16 = @truncate(area.top);
        while (text_iterator.next()) |data| {
            const codepoint, const utf8_len = data;
            defer current_char_offset += utf8_len;

            if (x > @as(u16, @truncate(area.right))) {
                if (codepoint[0] != '\n') {
                    while (text_iterator.next()) |data_| {
                        const codepoint_, const utf8_len_ = data_;
                        defer current_char_offset += utf8_len_;
                        if (codepoint_[0] == '\n') break;
                    }
                }
                y += 1;
                x = @truncate(area.left);
                continue;
            }
            if (y >= @as(u16, @truncate(area.bottom))) break;

            var fg_color = ed.Color.white;
            var bg_color = bg_color_;

            var cursor_kind: ed.CursorKind = .hidden;
            if (self.view.cursor_position >= self.view.start_position and current_char_offset == (self.view.cursor_position - self.view.start_position)) {
                cursor_kind = switch (self.mode) {
                    .insert => .bar,
                    .normal => .block,
                };
                renderer.set_cursor_style(.init(0xff, 0xdd, 0x33), bg_color);
                // std.mem.swap(ed.Color, &fg_color, &bg_color);
            }

            if (codepoint.len == 1) {
                switch (codepoint[0]) {
                    '\r' => {},
                    '\n' => {
                        renderer.place_glyph(x, y, &.{' '}, fg_color, bg_color, .red, .none, cursor_kind);
                        x += 1;
                        while (x < @as(u16, @truncate(area.right))) : (x += 1) {
                            fg_color = ed.Color.white;
                            bg_color = bg_color_;
                            renderer.place_glyph(x, y, &.{' '}, fg_color, bg_color, .red, .none, .hidden);
                        }
                        x = @truncate(area.left);
                        y += 1;
                    },
                    ' ' => {
                        renderer.place_glyph(x, y, &.{' '}, fg_color, bg_color, .red, .none, cursor_kind);
                        x += 1;
                    },
                    else => {
                        renderer.place_glyph(x, y, codepoint, fg_color, bg_color, .red, .none, cursor_kind);
                        x += 1;
                    },
                }
            }
        }

        while (y < @as(u16, @truncate(area.bottom))) : (y += 1) {
            x = 0;
            while (x < @as(u16, @truncate(area.right))) : (x += 1) {
                renderer.place_glyph(x, y, &.{' '}, .red, bg_color_, .red, .none, .hidden);
            }
        }

        // const cursor_coord = current_document.rope.lineColumnFromRelativePosition(self.view.start_position, self.view.cursor_position);
        // renderer.place_glyph(
        //     @truncate(cursor_coord[0] + area.left),
        //     @truncate(cursor_coord[1] + area.top),
        //     &.{' '},
        //     .white,
        //     .red,
        //     .red,
        //     .none,
        // );
    }
}
