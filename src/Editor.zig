const std = @import("std");
const ed = @import("ed.zig");
const keymap = @import("keymap");

comptime {
    _ = keymap;
}

pub const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
scratch: std.heap.ArenaAllocator,
documents: std.AutoHashMapUnmanaged(ed.Document.Id, ed.Document) = .empty,
next_document_id: ed.Document.Id = .{ .value = 1 },
current_document: ed.Document.Id = .nil,
view: ed.View = .{},

mode: enum {
    insert,
    normal,
    visual,
} = .normal,

saved_insert_node: ?*ed.Rope.Node = null,

key_dispatch_state: keymap.DispatchState = .{},

matcher: ?ed.Rope.Matcher = null,

pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
    return .{
        .io = io,
        .allocator = allocator,
        .scratch = .init(std.heap.page_allocator),
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
                .visual => self.handleVisualModeKeydown(event),
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
                const new_node = document.rope.insertString(self.view.cursor.head, "");
                self.saved_insert_node = new_node;
                break :blk new_node;
            };

            var out: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(@truncate(data.char), &out) catch @panic("invlaid utf8");
            node.appendSlice(self.allocator, out[0..utf8_len]) catch @panic("OOM");
            self.view.cursor.head += utf8_len;
            self.view.cursor.tail += utf8_len;
            self.view.max_column += utf8_len;
        },
        .escape => {
            self.key_dispatch_state = .{};
            self.mode = .normal;
            self.saved_insert_node = null;

            const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;

            if (self.view.cursor.head == line_range[0]) {
                self.view.max_column = 0;
            } else {
                self.view.cursor.head -|= 1;
                self.view.cursor.tail = self.view.cursor.head;
                self.view.max_column = self.view.cursor.head - line_range[0];
            }
        },
    }
}

pub fn handleNormalModeKeydown(self: *Self, event: ed.Event) void {
    const data = event.key_down;

    switch (data.key) {
        .char => {
            if (data.key == .char and (data.char & 0x7F) == data.char) {
                _ = keymap.dispatchNormalCommand(&self.key_dispatch_state, (@as(u16, @as(u3, @bitCast(data.modifers))) << 7) | @as(u7, @truncate(data.char)), self);
            }
        },
        .escape => {
            self.key_dispatch_state = .{};
            self.view.cursor.tail = self.view.cursor.head;
            self.mode = .normal;
        },
    }
}

pub fn handleVisualModeKeydown(self: *Self, event: ed.Event) void {
    const data = event.key_down;

    switch (data.key) {
        .char => {
            if (data.key == .char and (data.char & 0x7F) == data.char) {
                _ = keymap.dispatchVisualCommand(&self.key_dispatch_state, (@as(u16, @as(u3, @bitCast(data.modifers))) << 7) | @as(u7, @truncate(data.char)), self);
            }
        },
        .escape => {
            self.key_dispatch_state = .{};
            self.view.cursor.tail = self.view.cursor.head;
            self.mode = .normal;
        },
    }
}

pub fn setCursor(self: *Self, position: usize) void {
    switch (self.mode) {
        .normal, .insert => {
            self.view.cursor.head = position;
            self.view.cursor.tail = position;
        },
        .visual => {
            self.view.cursor.head = position;
        },
    }
}

pub fn moveCursorUp(self: *Self, line_count: u32, comptime move_cursor: bool) void {
    var coords = self.calculateCursorViewCoords();
    coords.column = @truncate(self.view.max_column);

    const document = self.documents.getPtr(self.current_document) orelse return;
    const new_start_position = document.rope.sub(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = line_count, .column = 0 },
        ed.Rope.Position,
    );

    self.view.start_position = new_start_position;

    if (move_cursor) {
        if (new_start_position == 0) {
            coords.line -|= line_count;
            self.setCursor(document.rope.add(
                new_start_position,
                coords,
                ed.Rope.Position,
            ));
        } else {
            self.setCursor(document.rope.add(
                new_start_position,
                coords,
                ed.Rope.Position,
            ));
        }
    }
}

pub fn moveCursorDown(self: *Self, line_count: u32, comptime move_cursor: bool) void {
    var coords = self.calculateCursorViewCoords();
    coords.column = @truncate(self.view.max_column);

    const document = self.documents.getPtr(self.current_document) orelse return;
    const new_start_position = document.rope.add(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = line_count, .column = 0 },
        ed.Rope.Position,
    );

    const max_pos = document.rope.sub(
        document.rope.len - 1,
        ed.Rope.Coordinate{ .line = self.view.lines - 2, .column = 0 },
        ed.Rope.Position,
    );
    self.view.start_position = @min(new_start_position, max_pos);

    if (move_cursor) {
        coords.line = @max(1, coords.line);
        self.setCursor(document.rope.add(
            new_start_position,
            coords,
            ed.Rope.Position,
        ));
    }
}

pub fn adjustViewToCursorPosition(self: *Self, cursor_position: usize) void {
    const document = self.documents.getPtr(self.current_document) orelse return;

    var old_coords = self.calculateCursorViewCoords();
    old_coords.column = 0;

    const new_coords = document.rope.lineColumnFromRelativePosition(self.view.start_position, cursor_position) orelse return;
    if (cursor_position >= self.view.start_position and new_coords.line + 5 <= self.view.lines) return;

    const new_start_position = document.rope.sub(cursor_position, old_coords, ed.Rope.Position);
    const line_range = document.rope.getLineRange(new_start_position) orelse return;

    const max_pos = document.rope.sub(
        document.rope.len - 1,
        ed.Rope.Coordinate{ .line = self.view.lines - 2, .column = 0 },
        ed.Rope.Position,
    );

    self.view.start_position = @min(line_range[0], max_pos);
}

// ********************* NORMAL COMMANDS *********************

pub fn commandEnterInsertMode(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
}

pub fn commandEnterInsertModeAppend(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
    self.view.cursor.head += 1;
    self.view.cursor.tail += 1;
}

pub fn commandEnterInsertModeStartOfLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    self.view.cursor.head = line_range[0];
    self.view.cursor.tail = line_range[0];
}

pub fn commandEnterInsertModeEndOfLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    self.view.cursor.head = line_range[1] -| 1;
    self.view.cursor.tail = line_range[1] -| 1;
}

pub fn commandEnterInsertModeAboveLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    _ = document.rope.insertString(line_range[0], "\n");

    self.view.cursor.head = line_range[0];
    self.view.cursor.tail = line_range[0];
}

pub fn commandEnterInsertModeBelowLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    _ = document.rope.insertString(line_range[1], "\n");

    self.view.cursor.head = line_range[1];
    self.view.cursor.tail = line_range[1];
}

pub fn commandEnterVisualMode(self: *Self, movement: ?Movement) void {
    _ = movement;
    self.mode = .visual;
}

pub fn commandDeleteMovement(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement(movement.?, .delete) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;
    _ = document.rope.deleteRange(movement_result.selection.tail, movement_result.selection.head);

    if (movement_result.linewise) {
        self.setCursor(movement_result.cursor_position);
    }
}

pub fn commandDeleteLine(self: *Self, movement: ?Movement) void {
    _ = movement;
    _ = self;
    std.debug.print("Delte line\n", .{});
}

pub fn commandDeleteUnder(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    _ = document.rope.deleteRange(ordered[0], ordered[1]);
}

pub fn commandChangeMovement(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement(movement.?, .delete) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;
    _ = document.rope.deleteRange(movement_result.selection.tail, movement_result.selection.head);

    if (movement_result.linewise) {
        self.setCursor(movement_result.cursor_position);
    }
    self.mode = .insert;
}

pub fn commandMoveUpHalfView(self: *Self, movement: ?Movement) void {
    _ = movement;

    const line_difference = self.view.lines / 2;
    self.moveCursorUp(line_difference, true);
}

pub fn commandMoveDownHalfView(self: *Self, movement: ?Movement) void {
    _ = movement;

    const line_difference = self.view.lines / 2;
    self.moveCursorDown(line_difference, true);
}

pub fn commandMove(self: *Self, movement: ?Movement) void {
    const movement_result = self.calculateKeyMovement(movement.?, .move);
    if (movement_result) |move| {
        self.setCursor(move.selection.head);
        self.view.max_column = move.max_column;

        const document = self.documents.getPtr(self.current_document) orelse return;

        // Cursor going before the start of the view is less expensive to calculate, so we do it first
        if (self.view.cursor.head < self.view.start_position) {
            const line_range = document.rope.getLineRange(self.view.cursor.head) orelse .{ 0, 0 };
            self.view.start_position = line_range[0];
        } else {
            const coords = self.calculateCursorViewCoords();
            if (coords.line + 3 > self.view.lines) {
                const line_difference = coords.line + 3 - self.view.lines;
                self.moveCursorDown(line_difference, false);
            }
        }
    }
}

// ********************* VISUAL COMMANDS *********************

pub fn commandVisualDelete(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1);

    if (self.view.cursor.tail < self.view.cursor.head) {
        self.view.cursor.head = self.view.cursor.tail;
    } else {
        self.view.cursor.tail = self.view.cursor.head;
    }
    self.mode = .normal;
}

pub fn commandVisualChange(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1);
    self.view.cursor.head = self.view.cursor.tail;
    self.mode = .insert;
}

pub fn commandVisualSearch(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.next();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        } else {
            m.wrapNext(&document.rope);

            match_opt = m.next();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
            }
        }
    } else {
        const range = self.view.cursor.getOrdered();
        const pattern_text = document.rope.toOwnedSlice(range[0], range[1] + 1, self.allocator);

        // @Robustness: memory leak
        const pattern = ed.Pattern.parseTokenBased(pattern_text, self.allocator);
        self.matcher = document.rope.matchStartingFrom(pattern, self.view.cursor.getOrdered()[1]);

        const match_opt = self.matcher.?.next();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        }
    }
}

pub fn commandVisualSearchReverse(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.prev();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        } else {
            m.wrapPrev(&document.rope);

            match_opt = m.prev();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
            }
        }
    } else {
        const range = self.view.cursor.getOrdered();
        const pattern_text = document.rope.toOwnedSlice(range[0], range[1] + 1, self.allocator);

        // @Robustness: memory leak
        const pattern = ed.Pattern.parseTokenBased(pattern_text, self.allocator);
        self.matcher = document.rope.matchStartingFrom(pattern, self.view.cursor.getOrdered()[1]);

        const match_opt = self.matcher.?.prev();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        }
    }
}

pub fn commandVisualSearchNext(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.next();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        } else {
            m.wrapNext(&document.rope);

            match_opt = m.next();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
            }
        }
    }
}

pub fn commandVisualSearchPrev(self: *Self, movement: ?Movement) void {
    _ = movement;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.prev();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
        } else {
            m.wrapPrev(&document.rope);

            match_opt = m.prev();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
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
    selection: ed.View.Selection = .{},
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
        .selection = self.view.cursor,
        .cursor_position = self.view.cursor.head,
        .max_column = self.view.max_column,
        .linewise = movementIsDefaultLinewise(movement),
    };
    switch (movement) {
        .right => {
            var do_max = true;
            if (document.rope.indexNode(self.view.cursor.head)) |node_and_offset| {
                const char = node_and_offset[0].string.items[node_and_offset[1]];
                if (char == '\n') {
                    result.max_column = 0;
                    do_max = false;
                }
            }
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = self.view.cursor.head + 1;
            result.cursor_position = self.view.cursor.head + 1;
            if (do_max) result.max_column = self.view.max_column + 1;
        },
        .left => {
            if (self.view.cursor.head > 0) {
                result.selection.tail = self.view.cursor.tail;
                result.selection.head = self.view.cursor.head - 1;
                result.cursor_position = self.view.cursor.head - 1;
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
            if (self.view.cursor.head > 0) {
                if (document.rope.getPreviousLineRange(self.view.cursor.head)) |last_line_range| {
                    switch (purpose) {
                        .move => {
                            result.cursor_position = @min(last_line_range[0] + self.view.max_column, last_line_range[1] -| 1);
                            result.selection.tail = self.view.cursor.tail;
                            result.selection.head = result.cursor_position;
                        },
                        .delete => {
                            const current_line_range = document.rope.getLineRange(self.view.cursor.head).?;
                            result.selection.tail = last_line_range[0];
                            result.selection.head = current_line_range[1];

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
            if (document.rope.getNextLineRange(self.view.cursor.head)) |next_line_range| {
                switch (purpose) {
                    .move => {
                        result.cursor_position = @min(next_line_range[0] + self.view.max_column, next_line_range[1] -| 1);
                        result.selection.tail = self.view.cursor.tail;
                        result.selection.head = result.cursor_position;
                    },
                    .delete => {
                        const current_line_range = document.rope.getLineRange(self.view.cursor.head).?;
                        result.selection.tail = current_line_range[0];
                        result.selection.head = next_line_range[1];

                        const after_line_range = document.rope.getLineRange(next_line_range[1]).?;
                        result.cursor_position = current_line_range[0] + @min(self.view.max_column, after_line_range[1] - after_line_range[0] - 1);
                    },
                }
            }
        },
        .word_forward => {
            const offset = document.rope.getNextWord(self.view.cursor.head);
            result.cursor_position = self.view.cursor.head + offset;
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = result.cursor_position;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_backward => {
            const offset = document.rope.getPreviousWord(self.view.cursor.head);
            result.cursor_position = self.view.cursor.head - offset;
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = result.cursor_position;

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .word_end_forward => {
            const offset = document.rope.getNextWordEnd(self.view.cursor.head);
            switch (purpose) {
                .move => {
                    result.cursor_position = self.view.cursor.head + offset;
                },
                .delete => {
                    result.cursor_position = self.view.cursor.head + offset + 1;
                },
            }
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = result.cursor_position; // inclusive

            const line_range = document.rope.getLineRange(result.cursor_position).?; // right now this can't return null
            result.max_column = result.cursor_position - line_range[0];
        },
        .start_of_line => {
            const line_range = document.rope.getLineRange(self.view.cursor.head).?; // right now this can't return null
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = line_range[0];
            result.cursor_position = line_range[0];
            result.max_column = 0;
        },
        .start_of_line_non_blank => {
            const line_range = document.rope.getLineRange(self.view.cursor.head).?; // right now this can't return null

            var current_offset = line_range[0];
            var current_node, var current_node_offset = document.rope.indexNode(line_range[0]).?;

            while (current_offset < document.rope.len) : (current_offset += 1) {
                switch (current_node.string.items[current_node_offset]) {
                    ' ', '\t', '\r' => {},
                    else => break,
                }

                current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
            }

            result.cursor_position = current_offset;
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = current_offset;

            result.max_column = result.cursor_position - line_range[0];
        },
        .end_of_line => {
            const line_range = document.rope.getLineRange(self.view.cursor.head).?; // right now this can't return null
            result.selection.tail = self.view.cursor.tail;
            result.selection.head = line_range[1];
            result.max_column = 0;
        },
    }
    return result;
}

pub fn calculateCursorViewCoords(self: *Self) ed.Rope.Coordinate {
    const current_document = self.documents.getPtr(self.current_document).?;
    const result = current_document.rope.lineColumnFromRelativePosition(self.view.start_position, self.view.cursor.head).?;
    // const result = current_document.rope.add(self.view.cursor_position, 0, ed.Rope.Coordinate);
    return result;
}

pub fn render(self: *Self, area: ed.Rect, renderer: *ed.Renderer) void {
    var output_buffer: [2]u16 = undefined;
    if (self.current_document.isValid()) {
        const current_document = self.documents.getPtr(self.current_document).?;
        var text_iterator = current_document.rope.iterUtf16StartingFrom(&output_buffer, self.view.start_position);

        const bg_color_ = ed.Color.init(40, 40, 60);
        var current_char_offset: usize = self.view.start_position;

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
            if (self.view.cursor.head >= self.view.start_position and current_char_offset == self.view.cursor.head) {
                cursor_kind = switch (self.mode) {
                    .insert => .bar,
                    .normal => .block,
                    .visual => .block,
                };
                renderer.set_cursor_style(.init(0xff, 0xdd, 0x33), bg_color);
            } else if (self.view.cursor.containsPosition(current_char_offset)) {
                bg_color = .red;
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
        if (true) {
            const mode_display = switch (self.mode) {
                .insert => .{ "INSERT", ed.Color.red },
                .normal => .{ "NORMAL", ed.Color.green },
                .visual => .{ "VISUAL", ed.Color.init(255, 0, 255) },
            };

            x = @truncate(area.left);
            y = @truncate(area.bottom - 2);
            for (mode_display[0]) |c| {
                renderer.place_glyph(x, y, &.{@as(u16, c)}, .init(0, 0, 0), mode_display[1], .red, .none, .hidden);
                x += 1;
            }
        }
    }
}
