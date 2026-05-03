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
            document.rope.dumpNodeToFile(document.rope.root.?, "out.dot") catch @panic("fjklsdjfsd");
        },
    }
}

pub fn handleNormalModeKeydown(self: *Self, event: ed.Event) void {
    const document = self.documents.getPtr(self.current_document) orelse return;
    _ = document;
    const data = event.key_down;

    if (data.key == .char and (data.char & 0x7F) == data.char) {
        _ = keymap.dispatchCommand(&self.key_dispatch_state, @truncate(data.char), self);
    }
}

pub fn commandEnterInsertMode(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
}

pub fn commandDeleteMovement(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement1(movement.?) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;
    std.debug.print("movement {} {}\n", .{ self.view.cursor_position, movement_result });
    _ = document.rope.deleteRange(self.view.cursor_position, movement_result.cursor_position);
}

pub fn commandDeleteLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    _ = self;
    std.debug.print("Delte line\n", .{});
}

pub fn commandMove(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement1(movement.?);
    if (movement_result) |move| {
        self.view.cursor_position = move.cursor_position;
        self.view.max_column = move.max_column;
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
};

pub fn calculateKeyMovement1(self: *Self, movement: Movement) ?keymap.KeyMovement {
    const document = self.documents.getPtr(self.current_document) orelse return null;

    var result = keymap.KeyMovement{
        .cursor_position = self.view.cursor_position,
        .max_column = self.view.max_column,
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
            result.cursor_position = self.view.cursor_position + 1;
            if (do_max) result.max_column = self.view.max_column + 1;
        },
        .left => {
            if (self.view.cursor_position > 0) {
                result.cursor_position = self.view.cursor_position - 1;
                result.max_column = self.view.max_column -| 1;

                if (document.rope.indexNode(result.cursor_position)) |node_and_offset| {
                    const char = node_and_offset[0].string.items[node_and_offset[1]];
                    if (char == '\n') {
                        const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                        result.max_column = line_range[1] - line_range[0];
                    }
                }
            }
        },
        .up => {
            if (self.view.cursor_position > 0) {
                if (document.rope.getPreviousLineRange(self.view.cursor_position)) |last_line_range| {
                    result.cursor_position = @min(last_line_range[0] + self.view.max_column, last_line_range[1]);
                }
            }
        },
        .down => {
            if (document.rope.getNextLineRange(self.view.cursor_position)) |next_line_range| {
                result.cursor_position = @min(next_line_range[0] + self.view.max_column, next_line_range[1]);
            }
        },
        .word_forward => {
            const offset = document.rope.getNextWord(self.view.cursor_position);
            result.cursor_position = self.view.cursor_position + offset;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_backward => {
            const offset = document.rope.getPreviousWord(self.view.cursor_position);
            result.cursor_position = self.view.cursor_position - offset;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_end_forward => {
            const offset = document.rope.getNextWordEnd(self.view.cursor_position);
            result.cursor_position = self.view.cursor_position + offset;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
    }
    return result;
}

pub fn calculateKeyMovement(self: *Self, event: ed.Event) ?keymap.KeyMovement {
    const document = self.documents.getPtr(self.current_document) orelse return;
    const data = event.key_down;

    var result = keymap.KeyMovement{ self.view.cursor_position, self.view.max_column };

    switch (data.key) {
        .char => {
            switch (data.char) {
                'l' => {
                    var do_max = true;
                    if (document.rope.indexNode(self.view.cursor_position)) |node_and_offset| {
                        const char = node_and_offset[0].string.items[node_and_offset[1]];
                        if (char == '\n') {
                            result.max_column = 0;
                            do_max = false;
                        }
                    }
                    result.cursor_position = self.view.cursor_position + 1;
                    if (do_max) result.max_column = self.view.max_column + 1;
                },
                'h' => {
                    if (self.view.cursor_position > 0) {
                        result.cursor_position = self.view.cursor_position - 1;
                        result.max_column = self.view.max_column -| 1;

                        if (document.rope.indexNode(result.cursor_position)) |node_and_offset| {
                            const char = node_and_offset[0].string.items[node_and_offset[1]];
                            if (char == '\n') {
                                const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                                result.max_column = line_range[1] - line_range[0];
                            }
                        }
                    }
                },
                'k' => {
                    if (self.view.cursor_position > 0) {
                        if (document.rope.getPreviousLineRange(self.view.cursor_position)) |last_line_range| {
                            result.cursor_position = @min(last_line_range[0] + self.view.max_column, last_line_range[1]);
                        }
                    }
                },
                'j' => {
                    if (document.rope.getNextLineRange(self.view.cursor_position)) |next_line_range| {
                        result.cursor_position = @min(next_line_range[0] + self.view.max_column, next_line_range[1]);
                    }
                },
                'w' => {
                    const offset = document.rope.getNextWord(self.view.cursor_position);
                    result.cursor_position = self.view.cursor_position + offset;

                    const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                    result.max_column = result.cursor_position - line_range[0];
                },
                'b' => {
                    const offset = document.rope.getPreviousWord(self.view.cursor_position);
                    result.cursor_position = self.view.cursor_position - offset;

                    const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                    result.max_column = result.cursor_position - line_range[0];
                },
                'e' => {
                    const offset = document.rope.getNextWordEnd(self.view.cursor_position);
                    result.cursor_position = self.view.cursor_position + offset;

                    const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
                    result.max_column = result.cursor_position - line_range[0];
                },
                else => return null,
            }
        },
        else => return null,
    }

    return result;
}

pub fn render(self: *Self, area: ed.Rect, renderer: *ed.Renderer) void {
    var scratch_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var output_buffer: [2]u16 = undefined;
    if (self.current_document.isValid()) {
        const current_document = self.documents.getPtr(self.current_document).?;
        var text_iterator = current_document.rope.iterUtf16(&output_buffer, scratch_allocator.allocator());

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
