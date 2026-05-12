const std = @import("std");
const ed = @import("ed.zig");
const keymap = @import("keymap");
const config = @import("config.zig");

comptime {
    _ = keymap;
}

pub const Self = @This();

const DispatchState = keymap.DispatchState(Movement);

application: *anyopaque,
application_vtable: *const ApplicationVtable,
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
    visual_line,
} = .normal,

registers: Registers = .{},
last_yanked_range: ?ed.View.Range = null,

saved_insert_node: ?*ed.Rope.Node = null,

key_dispatch_state: DispatchState = .{},

matcher: ?ed.Rope.Matcher = null,

last_find: ?u32 = null,
last_find_kind: ToTill = .to,

pub const ApplicationVtable = struct {
    start_timer: *const fn (data: *anyopaque, id: ed.TimerId, milliseconds: usize) void,
    kill_timer: *const fn (data: *anyopaque, id: ed.TimerId) void,
    quit: *const fn (data: *anyopaque) void,
    testing_step: *const fn (data: *anyopaque) void,
};

pub const ToTill = enum { to, till };

pub const Registers = struct {
    pub const Register = struct { []const u8, bool };
    registers: [127 - 32]Register = [1]Register{.{ "", false }} ** (127 - 32),

    pub fn setRegister(self: *Registers, register: u8, string: []const u8, linewise: bool) void {
        self.registers[register - 32] = .{ string, linewise };
    }

    pub fn getRegister(self: *Registers, register: u8) Register {
        return self.registers[register - 32];
    }
};

pub fn init(application: *anyopaque, application_vtable: *const ApplicationVtable, io: std.Io, allocator: std.mem.Allocator) Self {
    return .{
        .application = application,
        .application_vtable = application_vtable,
        .io = io,
        .allocator = allocator,
        .scratch = .init(std.heap.page_allocator),
    };
}

pub fn initTesting() Self {
    return .init(&dummy_application, &dummy_application_vtable, std.testing.io, std.testing.allocator);
}

pub fn quit(self: *Self) void {
    self.documents.deinit(self.allocator);
    self.scratch.deinit();
    self.application_vtable.quit(self.application);
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

pub fn applyEvents(self: *Self, key_event: []const ed.KeyDownEvent) void {
    for (key_event) |event| {
        self.handleEvent(.{ .key_down = event });
    }
}

pub fn testMotion(self: *Self, key_event: []const ed.KeyDownEvent, tail: usize, head: usize) !void {
    self.application_vtable.testing_step(self.application);

    for (key_event) |event| {
        self.handleEvent(.{ .key_down = event });
    }

    try std.testing.expectEqual(head, self.view.cursor.head);
    try std.testing.expectEqual(tail, self.view.cursor.tail);
}

pub fn testMotionLC(self: *Self, key_event: []const ed.KeyDownEvent, line: usize, column: usize) !void {
    self.application_vtable.testing_step(self.application);

    for (key_event) |event| {
        self.handleEvent(.{ .key_down = event });
    }

    const document = self.documents.getPtr(self.current_document) orelse return;
    const lc = document.rope.add(self.view.cursor.head, 0, ed.Rope.Coordinate);

    try std.testing.expectEqual(self.view.cursor.tail, self.view.cursor.head);
    try std.testing.expectEqual(line, lc.line);
    try std.testing.expectEqual(column, lc.column);
}

pub fn testMotionLCSplit(self: *Self, key_event: []const ed.KeyDownEvent, tail_line: usize, tail_column: usize, head_line: usize, head_column: usize) !void {
    self.application_vtable.testing_step(self.application);

    for (key_event) |event| {
        self.handleEvent(.{ .key_down = event });
    }

    const document = self.documents.getPtr(self.current_document) orelse return;
    const tlc = document.rope.add(self.view.cursor.tail, 0, ed.Rope.Coordinate);
    const hlc = document.rope.add(self.view.cursor.head, 0, ed.Rope.Coordinate);

    try std.testing.expectEqual(head_line, hlc.line);
    try std.testing.expectEqual(head_column, hlc.column);
    try std.testing.expectEqual(tail_line, tlc.line);
    try std.testing.expectEqual(tail_column, tlc.column);
}

pub fn handleEvent(self: *Self, event: ed.Event) void {
    switch (event) {
        .key_down => {
            switch (self.mode) {
                .insert => self.handleInsertModeKeydown(event),
                .normal => self.handleNormalModeKeydown(event),
                .visual, .visual_line => self.handleVisualModeKeydown(event),
            }
        },
        .timer => |timer_id| {
            switch (timer_id) {
                .yank_highlight => {
                    self.application_vtable.kill_timer(self.application, timer_id);
                    self.last_yanked_range = null;
                },
                _ => {},
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
            document.rope.len += utf8_len;
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
            if (data.key == .char and data.char == 'q') {
                self.quit();
            } else if (data.key == .char and (data.char & 0x7F) == data.char) {
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

            if (self.mode == .visual_line) blk: {
                const document = self.documents.getPtr(self.current_document) orelse break :blk;
                const line_range = document.rope.getLineRange(self.view.cursor.head) orelse break :blk;
                self.view.cursor.head = @min(line_range[0] + self.view.max_column, line_range[1] -| 1);
            }
            self.view.cursor.tail = self.view.cursor.head;

            self.mode = .normal;
        },
    }
}

pub fn collapseCursor(self: *Self, rope: *ed.Rope) void {
    var new_head: usize = 0;
    var new_tail: usize = 0;
    switch (self.mode) {
        .visual_line => {
            if (self.view.cursor.tail < self.view.cursor.head) {
                const line_range = rope.getLineRange(self.view.cursor.tail) orelse return;
                new_tail = @min(line_range[0] + self.view.max_column, line_range[1] -| 1);
                new_head = new_tail;
            } else {
                const line_range = rope.getLineRange(self.view.cursor.head) orelse return;
                new_head = @min(line_range[0] + self.view.max_column, line_range[1] -| 1);
                new_tail = new_head;
            }
        },
        .visual => {
            if (self.view.cursor.tail < self.view.cursor.head) {
                const line_range = rope.getLineRange(self.view.cursor.tail) orelse return;
                new_head = self.view.cursor.tail;
                new_tail = self.view.cursor.tail;
                self.view.max_column = new_tail - line_range[0];
            } else {
                const line_range = rope.getLineRange(self.view.cursor.head) orelse return;
                new_head = self.view.cursor.head;
                new_tail = self.view.cursor.head;
                self.view.max_column = new_head - line_range[0];
            }
        },
        else => unreachable,
    }
    self.adjustViewToCursorPosition(new_head);
    self.view.cursor.head = new_head;
    self.view.cursor.tail = new_tail;
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
        .visual_line => {
            const document = self.documents.getPtr(self.current_document) orelse return;
            const line_range = document.rope.getLineRange(position) orelse .{ 0, 0 };

            if (position < self.view.cursor.tail) {
                self.view.cursor.head = line_range[0];

                if (self.view.cursor.tail >= line_range[1]) {
                    const tail_line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
                    self.view.cursor.tail = tail_line_range[1] -| 1;
                } else {
                    self.view.cursor.tail = line_range[1] -| 1;
                }
            } else {
                self.view.cursor.head = line_range[1] -| 1;

                if (self.view.cursor.tail < line_range[0]) {
                    const tail_line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
                    self.view.cursor.tail = tail_line_range[0];
                } else {
                    self.view.cursor.tail = line_range[0];
                }
            }

            // if (position < self.view.cursor.tail) {
            //     self.view.cursor.head = line_range[0];
            // } else {
            //     self.view.cursor.head = line_range[1] -| 1;
            // }
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

pub fn commandEnterInsertMode(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
}

pub fn commandEnterInsertModeAppend(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
    self.view.cursor.head += 1;
    self.view.cursor.tail += 1;
}

pub fn commandEnterInsertModeStartOfLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    self.view.cursor.head = line_range[0];
    self.view.cursor.tail = line_range[0];
}

pub fn commandEnterInsertModeEndOfLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    self.view.cursor.head = line_range[1] -| 1;
    self.view.cursor.tail = line_range[1] -| 1;
}

pub fn commandEnterInsertModeAboveLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    _ = document.rope.insertString(line_range[0], "\n");

    self.view.cursor.head = line_range[0];
    self.view.cursor.tail = line_range[0];
}

pub fn commandEnterInsertModeBelowLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .insert;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
    _ = document.rope.insertString(line_range[1], "\n");

    self.view.cursor.head = line_range[1];
    self.view.cursor.tail = line_range[1];
}

pub fn commandReplace(self: *Self, dispatch: *DispatchState) void {
    const character = dispatch.characters[0];
    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1) orelse return;
    _ = document.rope.insertSplat(ordered[0], @truncate(character), ordered[1] - ordered[0] + 1);
}

pub fn commandFindNext(self: *Self, dispatch: *DispatchState) void {
    const character = dispatch.characters[0];
    const document = self.documents.getPtr(self.current_document) orelse return;
    const view_end = document.rope.add(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = self.view.lines + 1, .column = 0 },
        ed.Rope.Position,
    );
    var current_offset = self.view.cursor.head;
    self.last_find = character;
    self.last_find_kind = .to;
    var node, var node_offset = document.rope.indexNode(self.view.cursor.head) orelse return;

    var found = false;
    while (current_offset < view_end) : (current_offset += 1) {
        if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
            found = true;
            break;
        }
        node, node_offset = node.nextNodeChar(node_offset) orelse break;
    }

    if (found) self.setCursor(current_offset);
}

pub fn commandFindPrevious(self: *Self, dispatch: *DispatchState) void {
    const character = dispatch.characters[0];
    const document = self.documents.getPtr(self.current_document) orelse return;
    var current_offset = self.view.cursor.head;
    self.last_find = character;
    self.last_find_kind = .to;
    var node, var node_offset = document.rope.indexNode(self.view.cursor.head) orelse return;

    var found = false;
    while (current_offset >= self.view.start_position) : (current_offset -= 1) {
        if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
            found = true;
            break;
        }
        node, node_offset = node.previousNodeChar(node_offset) orelse break;
    }

    if (found) self.setCursor(current_offset);
}

pub fn commandFindTillNext(self: *Self, dispatch: *DispatchState) void {
    const character = dispatch.characters[0];
    const document = self.documents.getPtr(self.current_document) orelse return;
    const view_end = document.rope.add(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = self.view.lines + 1, .column = 0 },
        ed.Rope.Position,
    );
    var current_offset = self.view.cursor.head;
    self.last_find = character;
    self.last_find_kind = .till;
    var node, var node_offset = document.rope.indexNode(self.view.cursor.head) orelse return;

    var found = false;
    while (current_offset < view_end) : (current_offset += 1) {
        if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
            found = true;
            break;
        }
        node, node_offset = node.nextNodeChar(node_offset) orelse break;
    }

    if (found and current_offset > 0) self.setCursor(current_offset - 1);
}

pub fn commandFindTillPrevious(self: *Self, dispatch: *DispatchState) void {
    const character = dispatch.characters[0];
    const document = self.documents.getPtr(self.current_document) orelse return;
    var current_offset = self.view.cursor.head;
    self.last_find = character;
    self.last_find_kind = .till;
    var node, var node_offset = document.rope.indexNode(self.view.cursor.head) orelse return;

    var found = false;
    while (current_offset >= self.view.start_position) : (current_offset -= 1) {
        if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
            found = true;
            break;
        }
        node, node_offset = node.previousNodeChar(node_offset) orelse break;
    }

    if (found and current_offset + 1 < document.rope.len) self.setCursor(current_offset + 1);
}

pub fn commandFindAgainNext(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    if (self.last_find) |character| {
        switch (self.last_find_kind) {
            .to => self.commandFindNext(character),
            .till => self.commandFindTillNext(character),
        }
    }
}

pub fn commandFindAgainPrev(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    if (self.last_find) |character| {
        switch (self.last_find_kind) {
            .to => self.commandFindPrevious(character),
            .till => self.commandFindTillPrevious(character),
        }
    }
}

pub fn commandEnterVisualMode(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .visual;
}

pub fn commandEnterVisualLineMode(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    self.mode = .visual_line;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;

    if (self.view.cursor.head < self.view.cursor.tail) {
        self.view.cursor.head = line_range[0];

        if (self.view.cursor.tail >= line_range[1]) {
            const tail_line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
            self.view.cursor.tail = tail_line_range[1] -| 1;
        } else {
            self.view.cursor.tail = line_range[1] -| 1;
        }
    } else {
        self.view.cursor.head = line_range[1] -| 1;

        if (self.view.cursor.tail < line_range[0]) {
            const tail_line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
            self.view.cursor.tail = tail_line_range[0];
        } else {
            self.view.cursor.tail = line_range[0];
        }
    }
}

pub fn commandDeleteMovement(self: *Self, dispatch: *DispatchState) void {
    const movement_result = self.calculateKeyMovementQuery(dispatch.movement.?, dispatch.chars(), .select) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;

    if (movement_result.start < self.view.start_position) {
        const line_column = document.rope.lineColumnFromRelativePosition(movement_result.start, self.view.start_position).?;
        const lines = @min(line_column.line, self.view.lines / 2);

        const new_start_position = document.rope.sub(
            movement_result.start,
            ed.Rope.Coordinate{ .line = lines, .column = 0 },
            ed.Rope.Position,
        );
        self.view.start_position = new_start_position;
    }
    _ = document.rope.deleteRange(movement_result.start, movement_result.end);

    self.setCursor(movement_result.start);
    self.view.max_column = movement_result.max_column;
}

pub fn commandDeleteLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse {
        return;
    };
    _ = document.rope.deleteRange(line_range[0], line_range[1]);
}

pub fn commandDeleteUnder(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1);
}

pub fn commandChangeMovement(self: *Self, dispatch: *DispatchState) void {
    const movement_result = self.calculateKeyMovementQuery(dispatch.movement.?, dispatch.chars(), .select) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;

    if (movement_result.start < self.view.start_position) {
        const line_column = document.rope.lineColumnFromRelativePosition(movement_result.start, self.view.start_position).?;
        const lines = @min(line_column.line, self.view.lines / 2);

        const new_start_position = document.rope.sub(
            movement_result.start,
            ed.Rope.Coordinate{ .line = lines, .column = 0 },
            ed.Rope.Position,
        );
        self.view.start_position = new_start_position;
    }
    _ = document.rope.deleteRange(movement_result.start, movement_result.end);

    self.setCursor(movement_result.start);
    self.view.max_column = movement_result.max_column;

    self.mode = .insert;
}

pub fn commandYankMovement(self: *Self, dispatch: *DispatchState) void {
    const movement_result = self.calculateKeyMovementQuery(dispatch.movement.?, dispatch.chars(), .select) orelse return;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const slice = document.rope.toOwnedSlice(movement_result.start, movement_result.end, self.allocator);
    self.registers.setRegister('"', slice, movement_result.linewise);

    self.last_yanked_range = movement_result.toRange();
    self.application_vtable.start_timer(self.application, .yank_highlight, config.yank_highlight_time);
}

pub fn commandYankLine(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;
    const line_range = document.rope.getLineRange(self.view.cursor.head) orelse {
        self.registers.setRegister('"', "", true);
        self.last_yanked_range = .{ .start = 0, .end = 0 };
        return;
    };

    const slice = document.rope.toOwnedSlice(line_range[0], line_range[1], self.allocator);
    self.registers.setRegister('"', slice, true);

    self.last_yanked_range = .{ .start = line_range[0], .end = line_range[1] };

    self.application_vtable.start_timer(self.application, .yank_highlight, config.yank_highlight_time);
}

pub fn commandVisualYank(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const ordered = self.view.cursor.getOrdered();
    const slice = document.rope.toOwnedSlice(ordered[0], ordered[1] + 1, self.allocator);
    self.registers.setRegister('"', slice, (self.mode == .visual_line));

    self.last_yanked_range = self.view.cursor.toRange();
    self.application_vtable.start_timer(self.application, .yank_highlight, config.yank_highlight_time);

    if (self.mode == .visual_line) {
        const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
        self.view.cursor.head = @min(line_range[0] + self.view.max_column, line_range[1] -| 1);
    }
    self.view.cursor.tail = self.view.cursor.head;
    self.mode = .normal;
}

pub fn commandPasteAfter(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const text, const linewise = self.registers.getRegister('"');
    if (linewise) {
        const line_range = document.rope.getLineRange(self.view.cursor.head) orelse .{ 0, 0 };
        _ = document.rope.insertString(line_range[1], text);
        self.setCursor(line_range[1]);
    } else {
        _ = document.rope.insertString(@min(self.view.cursor.head + 1, document.rope.len), text);
    }
}

pub fn commandPasteBefore(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const text, const linewise = self.registers.getRegister('"');
    if (linewise) {
        const line_range = document.rope.getLineRange(self.view.cursor.head) orelse .{ 0, 0 };
        _ = document.rope.insertString(line_range[0], text);
        self.setCursor(line_range[0]);
    } else {
        _ = document.rope.insertString(self.view.cursor.head, text);
    }
}

pub fn commandMoveUpHalfView(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const line_difference = self.view.lines / 2;
    self.moveCursorUp(line_difference, true);
}

pub fn commandMoveDownHalfView(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const line_difference = self.view.lines / 2;
    self.moveCursorDown(line_difference, true);
}

pub fn commandMove(self: *Self, dispatch: *DispatchState) void {
    const movement_result = self.calculateKeyMovementQuery(dispatch.movement.?, dispatch.chars(), .move);
    if (movement_result) |move| {
        const document = self.documents.getPtr(self.current_document) orelse return;

        self.setCursor(move.position);
        if (self.mode != .visual_line) {
            self.view.max_column = move.max_column;
        }

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

pub fn commandIndentIn(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();

    const start_range = document.rope.getLineRange(ordered[0]) orelse .{ 0, 0 };
    _ = document.rope.insertString(start_range[0], "    ");

    const end_range = if (ordered[1] != ordered[0])
        document.rope.getLineRange(ordered[1] + 4) orelse .{ 0, 0 }
    else {
        self.view.cursor.head += 4;
        self.view.cursor.tail += 4;
        return;
    };

    if (start_range[0] == end_range[0]) {
        self.view.cursor.head += 4;
        self.view.cursor.tail += 4;
        return;
    }

    var current_offset = start_range[0] + 4;
    var node, var node_offset = document.rope.indexNode(current_offset) orelse return;
    var increment_cursor: usize = 0;

    while (current_offset < end_range[1] + increment_cursor - 4) : (current_offset += 1) {
        switch (node.string.items[node_offset]) {
            '\n' => {
                const inserted_node = document.rope.insertString(current_offset + 1, "    ");
                // this would have been the next node, before inserting
                const inserted_node_next, const inserted_node_next_offset = inserted_node.nthNextNodeChar(0, 4) orelse @panic("unhandled");
                current_offset += 4;
                increment_cursor += 4;

                node = inserted_node_next;
                node_offset = inserted_node_next_offset;
            },
            else => {
                const next_node, const next_node_offset = node.nextNodeChar(node_offset) orelse break;
                node = next_node;
                node_offset = next_node_offset;
            },
        }
    }

    if (self.view.cursor.head < self.view.cursor.tail) {
        if (self.mode == .visual_line) {
            self.view.cursor.tail += increment_cursor + 4;
        } else {
            self.view.cursor.head += 4;
            self.view.cursor.tail += increment_cursor + 4;
        }
    } else {
        if (self.mode == .visual_line) {
            self.view.cursor.head += increment_cursor + 4;
        } else {
            self.view.cursor.tail += 4;
            self.view.cursor.head += increment_cursor + 4;
        }
    }
}

pub fn commandIndentOut(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;
    const document = self.documents.getPtr(self.current_document) orelse return;

    const ordered = self.view.cursor.getOrdered();
    const start_range = document.rope.getLineRange(ordered[0]) orelse .{ 0, 0 };
    const end_range = if (ordered[1] != ordered[0])
        document.rope.getLineRange(ordered[1]) orelse .{ 0, 0 }
    else
        start_range;

    var range_iterator = document.rope.rangeIter(start_range[0], end_range[1]);
    var sb = ed.Rope.GrowableString.initCapacity(document.rope.allocator, ordered[1] - ordered[0]) catch @panic("OOM");

    var start: usize = 0;
    var skip_indent = true;
    var indent: usize = 0;
    var cursor_indent: usize = 0;
    var first_indent: usize = 0;
    var last_indent: usize = 0;
    var characters_added: usize = 0;

    while (range_iterator.next()) |slice| {
        start = 0;

        for (slice, 0..) |item, i| {
            switch (item) {
                '\n' => {
                    sb.appendSlice(document.rope.allocator, slice[start .. i + 1]) catch @panic("OOM");
                    indent = 0;
                    skip_indent = true;
                    start = i + 1;
                },
                else => {
                    if (skip_indent) {
                        if (item == ' ') indent += 1;
                        if (item == '\t') indent += 4;

                        if (indent >= 4) {
                            skip_indent = false;
                            start = i + 1;

                            if (cursor_indent == 0) first_indent = indent else last_indent = indent;
                            characters_added += indent;

                            cursor_indent += 1;
                        } else if (item != ' ') {
                            skip_indent = false;
                            start = i;

                            if (cursor_indent == 0) first_indent = indent else last_indent = indent;
                            characters_added += indent;

                            cursor_indent += 1;
                        }
                    }
                },
            }
        }

        if (start < slice.len) {
            sb.appendSlice(document.rope.allocator, slice[start..]) catch @panic("OOM");
        }
    }

    _ = document.rope.deleteRange(start_range[0], end_range[1]).?;
    _ = document.rope.insertGrowableString(start_range[0], sb);

    if (self.view.cursor.head < self.view.cursor.tail) {
        if (self.mode == .visual_line) {
            self.view.cursor.head = start_range[0];
            self.view.cursor.tail -= characters_added;
        } else {
            const new_head = @max(start_range[0], self.view.cursor.head -| first_indent);
            self.view.cursor.tail -= characters_added;
            self.view.cursor.head = new_head;
        }
    } else {
        if (self.mode == .visual_line) {
            self.view.cursor.tail = start_range[0];
            self.view.cursor.head -= characters_added;
        } else {
            const new_tail = @max(start_range[0], self.view.cursor.tail -| first_indent);
            self.view.cursor.head -= characters_added;
            self.view.cursor.tail = new_tail;
        }
    }
}

// pub fn commandIndentOut1(self: *Self, dispatch: *DispatchState) void {
//     _ = dispatch;

//     const document = self.documents.getPtr(self.current_document) orelse return;
//     const ordered = self.view.cursor.getOrdered();

//     const start_range = document.rope.getLineRange(ordered[0]) orelse .{ 0, 0 };

//     var current_offset = start_range[0];
//     var node, var node_offset = document.rope.indexNode(current_offset) orelse return;

//     var indent_level: usize = 0;
//     while (current_offset < start_range[1] and indent_level < 4) : (current_offset += 1) {
//         switch (node.string.items[node_offset]) {
//             ' ' => indent_level += 1,
//             '\t' => indent_level += 4,
//             else => break,
//         }

//         node, node_offset = node.nextNodeChar(node_offset) orelse break;
//     }

//     _ = document.rope.deleteRange(start_range[0], current_offset);

//     const end_range = if (ordered[1] != ordered[0])
//         document.rope.getLineRange(ordered[1]) orelse .{ 0, 0 }
//     else {
//         self.view.cursor.head -|= indent_level;
//         self.view.cursor.tail -|= indent_level;
//         return;
//     };

//     if (start_range[0] == end_range[0]) {
//         if (self.view.cursor.head < self.view.cursor.tail) {
//             const new_head = @max(start_range[0], self.view.cursor.head -| indent_level);
//             self.view.cursor.tail -|= indent_level;
//             self.view.cursor.head = new_head;
//         } else {
//             const new_tail = @max(start_range[0], self.view.cursor.tail -| indent_level);
//             self.view.cursor.head -|= indent_level;
//             self.view.cursor.tail = new_tail;
//         }
//         return;
//     }

//     current_offset = start_range[1] - indent_level - 1;
//     node, node_offset = document.rope.indexNode(current_offset) orelse return;

//     var increment_cursor: usize = 0;
//     var increment_end: usize = 0;

//     var start_removing = false;
//     var start: usize = 0;

//     while (current_offset <= end_range[1] - increment_end) : (current_offset += 1) {
//         {
//             // const ind, const ind_off = document.rope.indexNode(current_offset) orelse return;
//             // std.debug.print("thing: '{c}', '{c}'\n", .{node.string.items[node_offset], ind.string.items[ind_off]});
//         }
//         switch (node.string.items[node_offset]) {
//             '\n' => {
//                 start_removing = true;
//                 start = current_offset + 1;
//                 indent_level = 0;

//                 const next_node, const next_node_offset = node.nextNodeChar(node_offset) orelse break;
//                 node = next_node;
//                 node_offset = next_node_offset;
//             },
//             else => |c| {
//                 if (start_removing) {
//                     if (c == ' ') indent_level += 1;
//                     if (c == '\t') indent_level += 4;
//                     if (indent_level >= 4) {
//                         start_removing = false;

//                         if (indent_level > node_offset) {
//                             const next_node, const next_node_offset = node.nextNodeChar(node_offset) orelse break;
//                             _, _, const split_node = document.rope.deleteRange(start, current_offset + 1) orelse break;
//                             // document.rope.dumpGraphToFile("indentout.dot") catch @panic("flkjsdf");
//                             std.debug.print("indent i ssmalelr {}\n", .{indent_level});

//                             std.debug.print("{*} {} {} {} {*} {}   {*} {}\n", .{ node, node.string.items.len, node_offset, indent_level, split_node, split_node.string.items.len, next_node, next_node_offset });
//                             // node = next_node;
//                             // node_offset = next_node_offset;
//                             node = split_node;
//                             node_offset = 0;

//                             if (next_node == split_node) {
//                                 increment_cursor += indent_level;
//                             }
//                             increment_end += indent_level;
//                             current_offset -= indent_level;
//                             continue;
//                         }

//                         _ = document.rope.deleteRange(start, current_offset + 1);
//                         increment_cursor += indent_level;
//                         increment_end += indent_level;
//                         node_offset -= indent_level;
//                         current_offset -= indent_level;
//                     } else if (c != ' ') {
//                         start_removing = false;

//                         if (current_offset > start) {
//                             _ = document.rope.deleteRange(start, current_offset);
//                             increment_cursor += indent_level;
//                             increment_end += indent_level;
//                             node_offset -= indent_level;
//                             current_offset -= indent_level;
//                         }
//                     }
//                 }

//                 const next_node, const next_node_offset = node.nextNodeChar(node_offset) orelse break;
//                 node = next_node;
//                 node_offset = next_node_offset;
//             },
//         }
//     }

//     std.debug.print("shift in {}\n", .{increment_cursor});

//     if (self.view.cursor.head < self.view.cursor.tail) {} else {
//         self.view.cursor.head -= increment_cursor;
//     }
// }

// ********************* VISUAL COMMANDS *********************

pub fn commandVisualDelete(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    if (self.view.cursor.tail < self.view.cursor.head) {
        if (self.view.cursor.tail < self.view.start_position) {
            const line_column = document.rope.lineColumnFromRelativePosition(self.view.cursor.tail, self.view.start_position).?;
            const lines = @min(line_column.line, self.view.lines / 2);

            const new_start_position = document.rope.sub(
                self.view.cursor.tail,
                ed.Rope.Coordinate{ .line = lines, .column = 0 },
                ed.Rope.Position,
            );
            self.view.start_position = new_start_position;
        }
    }
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1);
    self.collapseCursor(&document.rope);
    self.mode = .normal;
}

pub fn commandVisualChange(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;
    const ordered = self.view.cursor.getOrdered();
    if (self.view.cursor.tail < self.view.cursor.head) {
        if (self.view.cursor.tail < self.view.start_position) {
            const line_column = document.rope.lineColumnFromRelativePosition(self.view.cursor.tail, self.view.start_position).?;
            const lines = @min(line_column.line, self.view.lines / 2);

            const new_start_position = document.rope.sub(
                self.view.cursor.tail,
                ed.Rope.Coordinate{ .line = lines, .column = 0 },
                ed.Rope.Position,
            );
            self.view.start_position = new_start_position;
        }
    }
    _ = document.rope.deleteRange(ordered[0], ordered[1] + 1);
    self.collapseCursor(&document.rope);
    self.mode = .insert;
}

pub fn commandVisualSearch(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| blk: {
        const range = self.view.cursor.getOrdered();
        const pattern_text = document.rope.toOwnedSlice(range[0], range[1] + 1, self.scratch.allocator());

        if (!m.pattern.matches(pattern_text)[0]) break :blk;

        m.setCurrent(&document.rope, range[1]);
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

        return;
    }
    {
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

pub fn commandVisualSearchReverse(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| blk: {
        const range = self.view.cursor.getOrdered();
        const pattern_text = document.rope.toOwnedSlice(range[0], range[1] + 1, self.scratch.allocator());

        if (!m.pattern.matches(pattern_text)[0]) break :blk;

        m.setCurrent(&document.rope, range[0]);
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

        return;
    }

    {
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

pub fn commandVisualSearchNext(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.next();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
            self.mode = .visual;
        } else {
            m.wrapNext(&document.rope);

            match_opt = m.next();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
                self.mode = .visual;
            }
        }
    }
}

pub fn commandVisualSearchPrev(self: *Self, dispatch: *DispatchState) void {
    _ = dispatch;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.matcher) |*m| {
        var match_opt = m.prev();
        if (match_opt) |match| {
            self.adjustViewToCursorPosition(match.getOrdered()[0]);
            self.view.cursor = match;
            self.mode = .visual;
        } else {
            m.wrapPrev(&document.rope);

            match_opt = m.prev();
            if (match_opt) |match| {
                self.adjustViewToCursorPosition(match.getOrdered()[0]);
                self.view.cursor = match;
                self.mode = .visual;
            }
        }
    }
}

fn textObjectCommon(self: *Self, dispatch: *DispatchState, movement: Movement) void {
    const movement_result = self.calculateKeyMovementQuery(movement, dispatch.chars(), .select) orelse return;

    const document = self.documents.getPtr(self.current_document) orelse return;

    if (self.view.cursor.head < self.view.cursor.tail) {
        self.adjustViewToCursorPosition(movement_result.start);
    } else {
        self.adjustViewToCursorPosition(movement_result.end - 1);
    }

    if (self.view.cursor.head != self.view.cursor.tail) {
        if (self.view.cursor.head < self.view.cursor.tail) {
            if (movement_result.start < self.view.cursor.head) {
                self.view.cursor.head = movement_result.start;
            }
            if (movement_result.end > self.view.cursor.tail) {
                self.view.cursor.tail = @max(self.view.cursor.head, movement_result.end -| 1);
            }
        } else {
            if (movement_result.start < self.view.cursor.tail) {
                self.view.cursor.tail = movement_result.start;
            }
            if (movement_result.end > self.view.cursor.head) {
                self.view.cursor.head = @max(self.view.cursor.tail, movement_result.end -| 1);
            }
        }
    } else {
        self.view.cursor = movement_result.toRange().toSelection();
    }

    switch (self.mode) {
        .visual => {
            const line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
            self.view.max_column = self.view.cursor.head - line_range[0];
        },
        .visual_line => {
            const line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
            if (self.view.cursor.head < self.view.cursor.tail) {
                self.view.cursor.head = line_range[0];
                if (self.view.cursor.tail > line_range[1]) {
                    const end_line_range = document.rope.getLineRange(self.view.cursor.tail) orelse return;
                    self.view.cursor.tail = end_line_range[1];
                } else {
                    self.view.cursor.tail = line_range[1];
                }
            } else {
                self.view.cursor.tail = line_range[0];
                if (self.view.cursor.head > line_range[1]) {
                    const end_line_range = document.rope.getLineRange(self.view.cursor.head) orelse return;
                    self.view.cursor.head = end_line_range[1];
                } else {
                    self.view.cursor.head = line_range[1];
                }
            }
        },
        else => unreachable,
    }

}

pub fn commandVisualTextObjectInner(self: *Self, dispatch: *DispatchState) void {
    textObjectCommon(self, dispatch, .text_object_inner);
}

pub fn commandVisualTextObjectOuter(self: *Self, dispatch: *DispatchState) void {
    textObjectCommon(self, dispatch, .text_object_outer);
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

    find_next,
    find_prev,
    find_till_next,
    find_till_prev,
    find_again_next,
    find_again_prev,

    text_object_inner,
    text_object_outer,
};

pub const KeyMovementTag = enum {
    move,
    select,
};

pub const KeyMovementMove = usize;
pub const KeyMovementSelect = ed.View.Range;

pub fn KeyMovement(comptime query: KeyMovementTag) type {
    return switch (query) {
        .move => struct {
            position: usize,
            max_column: usize,
            linewise: bool = false,

            pub inline fn init(position: usize, max_column: usize, linewise: bool) @This() {
                return .{ .position = position, .max_column = max_column, .linewise = linewise };
            }

            pub inline fn initCalcColumn(rope: *ed.Rope, position: usize) @This() {
                const line_range = rope.getLineRange(position).?;
                return .{ .position = position, .max_column = position - line_range[0] };
            }

            pub inline fn toRange(self: @This()) ed.View.Range {
                return .{ .start = self.start, .end = self.end };
            }
        },
        .select => struct {
            start: usize,
            end: usize,
            max_column: usize,
            linewise: bool = false,

            pub inline fn init(start: usize, end: usize, max_column: usize, linewise: bool) @This() {
                return .{ .start = start, .end = end, .max_column = max_column, .linewise = linewise };
            }

            pub inline fn initCalcColumn(rope: *ed.Rope, start: usize, end: usize) @This() {
                const end_o = @max(start, end -| 1);
                const line_range = rope.getLineRange(end_o).?;
                return .{ .start = start, .end = end, .max_column = end_o - line_range[0], .linewise = false };
            }

            pub inline fn toRange(self: @This()) ed.View.Range {
                return .{ .start = self.start, .end = self.end };
            }
        },
    };
}

pub fn calculateKeyMovementQuery(self: *Self, movement: Movement, chars: []const u32, comptime query: KeyMovementTag) ?KeyMovement(query) {
    const document = self.documents.getPtr(self.current_document) orelse return null;

    const cursor = self.view.cursor.head;
    switch (movement) {
        .right => {
            return switch (query) {
                .move => .initCalcColumn(&document.rope, cursor + 1),
                .select => .initCalcColumn(&document.rope, cursor, cursor + 1),
            };
        },
        .left => {
            if (cursor > 0) {
                return switch (query) {
                    .move => .initCalcColumn(&document.rope, cursor - 1),
                    .select => .initCalcColumn(&document.rope, cursor - 1, cursor),
                };
            }
        },
        .up => {
            if (cursor > 0) {
                if (document.rope.getPreviousLineRange(cursor)) |last_line_range| {
                    switch (query) {
                        .move => {
                            const position = @min(last_line_range[0] + self.view.max_column, last_line_range[1] -| 1);
                            return .init(position, self.view.max_column, true);
                        },
                        .select => {
                            const current_line_range = document.rope.getLineRange(cursor).?;
                            return .init(last_line_range[0], current_line_range[1], self.view.max_column, true);
                        },
                    }
                }
            }
        },
        .down => {
            if (document.rope.getNextLineRange(cursor)) |next_line_range| {
                switch (query) {
                    .move => {
                        const position = @min(next_line_range[0] + self.view.max_column, next_line_range[1] -| 1);
                        return .init(position, self.view.max_column, true);
                    },
                    .select => {
                        const current_line_range = document.rope.getLineRange(cursor).?;
                        return .init(current_line_range[0], next_line_range[1], self.view.max_column, true);
                    },
                }
            }
        },
        .word_forward => {
            const offset = document.rope.getNextWord(cursor);
            return switch (query) {
                .move => .initCalcColumn(&document.rope, cursor + offset),
                .select => .initCalcColumn(&document.rope, cursor, cursor + offset),
            };
        },
        .word_backward => {
            const offset = document.rope.getPreviousWord(cursor);
            return switch (query) {
                .move => .initCalcColumn(&document.rope, cursor - offset),
                .select => .initCalcColumn(&document.rope, cursor - offset, cursor - 1),
            };
        },
        .word_end_forward => {
            const offset = document.rope.getNextWordEnd(cursor);
            return switch (query) {
                .move => .initCalcColumn(&document.rope, cursor + offset),
                .select => .initCalcColumn(&document.rope, cursor, cursor + offset + 1),
            };
        },
        .start_of_line => {
            const line_range = document.rope.getLineRange(cursor).?; // right now this can't return null
            return switch (query) {
                .move => .init(line_range[0], 0, false),
                .select => .init(line_range[0], cursor, 0, false),
            };
        },
        .start_of_line_non_blank => {
            const line_range = document.rope.getLineRange(cursor).?; // right now this can't return null

            var current_offset = line_range[0];
            var current_node, var current_node_offset = document.rope.indexNode(line_range[0]).?;

            while (current_offset < document.rope.len) : (current_offset += 1) {
                switch (current_node.string.items[current_node_offset]) {
                    ' ', '\t', '\r' => {},
                    else => break,
                }

                current_node, current_node_offset = current_node.nextNodeChar(current_node_offset) orelse break;
            }

            return switch (query) {
                .move => .init(current_offset, current_offset - line_range[0], false),
                .select => .init(current_offset, cursor, current_offset - line_range[0], false),
            };
        },
        .end_of_line => {
            const line_range = document.rope.getLineRange(cursor).?; // right now this can't return null
            switch (query) {
                .move => {
                    const position = @max(line_range[0], line_range[1] -| 2);
                    return .init(position, position - line_range[0], false);
                },
                .select => {
                    const position = @max(line_range[0], line_range[1] -| 1);
                    return .init(cursor, position, position - line_range[0], false);
                },
            }
        },
        .find_next => {
            const character = chars[0];
            if (self.findCharacter(&document.rope, @truncate(character), true, .to)) |position| {
                return switch (query) {
                    .move => .initCalcColumn(&document.rope, position),
                    .select => .initCalcColumn(&document.rope, cursor, position),
                };
            }
        },
        .find_prev => {
            const character = chars[0];
            if (self.findCharacter(&document.rope, @truncate(character), false, .to)) |position| {
                return switch (query) {
                    .move => .initCalcColumn(&document.rope, position),
                    .select => .initCalcColumn(&document.rope, cursor, position),
                };
            }
        },
        .find_till_next => {
            const character = chars[0];
            if (self.findCharacter(&document.rope, @truncate(character), true, .till)) |position| {
                return switch (query) {
                    .move => .initCalcColumn(&document.rope, position),
                    .select => .initCalcColumn(&document.rope, cursor, position),
                };
            }
        },
        .find_till_prev => {
            const character = chars[0];
            if (self.findCharacter(&document.rope, @truncate(character), false, .till)) |position| {
                return switch (query) {
                    .move => .initCalcColumn(&document.rope, position),
                    .select => .initCalcColumn(&document.rope, cursor, position),
                };
            }
        },
        .find_again_next => {
            if (self.last_find) |lf| {
                if (self.findCharacter(&document.rope, @truncate(lf), true, self.last_find_kind)) |position| {
                    return switch (query) {
                        .move => .initCalcColumn(&document.rope, position),
                        .select => .initCalcColumn(&document.rope, cursor, position),
                    };
                }
            }
        },
        .find_again_prev => {
            if (self.last_find) |lf| {
                if (self.findCharacter(&document.rope, @truncate(lf), false, self.last_find_kind)) |position| {
                    return switch (query) {
                        .move => .initCalcColumn(&document.rope, position),
                        .select => .initCalcColumn(&document.rope, cursor, position),
                    };
                }
            }
        },
        .text_object_inner => if (query == .select) blk: {
            const character = chars[0];
            const textobject = ed.TextObject.fromChar(character) orelse break :blk;

            switch (self.mode) {
                .visual_line => {
                    switch (textobject) {
                        .paren, .bracket, .brace => self.mode = .visual,
                        else => {},
                    }
                },
                else => {},
            }

            const ordered = self.view.cursor.getOrdered();
            const range = document.rope.getTextObject(textobject, false, ordered[0]);

            return .initCalcColumn(&document.rope, range[0], range[1]);
        },
        .text_object_outer => if (query == .select) blk: {
            const character = chars[0];
            const textobject = ed.TextObject.fromChar(character) orelse break :blk;

            switch (self.mode) {
                .visual_line => {
                    switch (textobject) {
                        .paren, .bracket, .brace => self.mode = .visual,
                        else => {},
                    }
                },
                else => {},
            }

            const ordered = self.view.cursor.getOrdered();
            const range = document.rope.getTextObject(textobject, true, ordered[0]);

            return .initCalcColumn(&document.rope, range[0], range[1]);
        },
    }

    return switch (query) {
        .move => .init(cursor, self.view.max_column, false),
        .select => .init(cursor, cursor, self.view.max_column, false),
    };
}

pub fn findCharacter(self: *Self, rope: *ed.Rope, character: u8, comptime forwards: bool, kind: ToTill) ?usize {
    self.last_find = character;
    self.last_find_kind = kind;

    const view_end = rope.add(
        self.view.start_position,
        ed.Rope.Coordinate{ .line = self.view.lines + 1, .column = std.math.maxInt(u32) },
        ed.Rope.Position,
    );
    var current_offset = if (forwards)
        @min(self.view.cursor.head + 1, rope.len)
    else
        self.view.cursor.head -| 1;
    var node, var node_offset = rope.indexNode(current_offset) orelse return null;

    var found = false;
    if (forwards) {
        while (current_offset < view_end) : (current_offset += 1) {
            if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
                found = true;
                break;
            }
            node, node_offset = node.nextNodeChar(node_offset) orelse break;
        }
    } else {
        while (current_offset > 0) : (current_offset -= 1) {
            if (node.string.items[node_offset] == @as(u8, @truncate(character))) {
                found = true;
                break;
            }
            node, node_offset = node.previousNodeChar(node_offset) orelse break;
        }
    }

    if (found) {
        if (kind == .till) {
            if (forwards) {
                return if (current_offset > 0) current_offset - 1 else null;
            } else {
                return if (current_offset + 1 < rope.len) current_offset + 1 else null;
            }
        }

        return current_offset;
    } else {
        return null;
    }
}

pub fn calculateCursorViewCoords(self: *Self) ed.Rope.Coordinate {
    const current_document = self.documents.getPtr(self.current_document).?;
    const result = current_document.rope.lineColumnFromRelativePosition(self.view.start_position, self.view.cursor.head).?;
    // const result = current_document.rope.add(self.view.cursor_position, 0, ed.Rope.Coordinate);
    return result;
}

pub fn finish_frame(self: *Self) void {
    _ = self.scratch.reset(.retain_capacity);
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
                    .visual_line => .block,
                };
                renderer.set_cursor_style(.init(0xff, 0xdd, 0x33), bg_color);
            } else if (self.view.cursor.containsPosition(current_char_offset)) {
                bg_color = .red;
            } else if (self.last_yanked_range) |yank_range| {
                if (yank_range.containsPosition(current_char_offset)) {
                    fg_color = bg_color;
                    bg_color = .green;
                }
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
                .insert => .{ "INSERT", ed.Color.red, ed.UnderlineStyle.none },
                .normal => .{ "NORMAL", ed.Color.green, ed.UnderlineStyle.none },
                .visual => .{ "VISUAL", ed.Color.init(255, 0, 255), ed.UnderlineStyle.none },
                .visual_line => .{ " LINE ", ed.Color.init(0, 200, 255), ed.UnderlineStyle.line },
            };

            x = @truncate(area.left);
            y = @truncate(area.bottom - 2);
            for (mode_display[0]) |c| {
                if (c == ' ') {
                    renderer.place_glyph(x, y, &.{@as(u16, c)}, .init(0, 0, 0), mode_display[1], .init(0, 0, 0), .none, .hidden);
                } else {
                    renderer.place_glyph(x, y, &.{@as(u16, c)}, .init(0, 0, 0), mode_display[1], .init(0, 0, 0), mode_display[2], .hidden);
                }
                x += 1;
            }

            var number_buf: [16]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buf, "{:6}", .{self.view.cursor.head}) catch @panic("buffer to small!");
            x = @as(u16, @truncate(area.right)) - @as(u16, @truncate(number.len)) - 2;

            for (number) |c| {
                renderer.place_glyph(x, y, &.{@as(u16, c)}, .white, .init(20, 20, 20), .init(0, 0, 0), .none, .hidden);
                x += 1;
            }
            renderer.place_glyph(x, y, &.{' '}, .white, .init(20, 20, 20), .init(0, 0, 0), .none, .hidden);
        }
    }
}

var dummy_application: void = {};
var dummy_application_vtable: ApplicationVtable = .{
    .start_timer = dummy_start_timer,
    .kill_timer = dummy_kill_timer,
    .quit = dummy_quit,
    .testing_step = dummy_step,
};

fn dummy_start_timer(app: *anyopaque, id: ed.TimerId, milliseconds: usize) void {
    _ = app;
    _ = id;
    _ = milliseconds;
}

fn dummy_kill_timer(app: *anyopaque, id: ed.TimerId) void {
    _ = app;
    _ = id;
}

fn dummy_quit(app: *anyopaque) void {
    _ = app;
}

fn dummy_step(app: *anyopaque) void {
    _ = app;
}

pub const TestApp = struct {
    app: ?*ed.Application = null,
    editor: *ed.Editor,

    pub const debug = false;

    pub fn create(file_path: []const u8, src: std.builtin.SourceLocation) TestApp {
        if (debug) {
            const application = ed.Application.createTesting(file_path, src);
            const editor = application.getEditor();
            return .{ .app = application, .editor = editor };
        } else {
            const editor = std.testing.allocator.create(ed.Editor) catch @panic("OOM");
            editor.* = Self.initTesting();
            editor.resize(50, 80);
            editor.openDocument(file_path);
            return .{ .app = null, .editor = editor };
        }
    }

    pub fn deinit(app: *TestApp) void {
        if (app.app) |a| a.deinit();
        app.editor.quit();
        if (app.app == null) {
            std.testing.allocator.destroy(app.editor);
        }
    }
};

// const document = editor.documents.getPtr(editor.current_document).?;
// var node_iter = document.rope.nodeIter();
// while (node_iter.next()) |node| {
//     std.debug.print("node: '{s}'\n", .{node.string.items});
// };

test "Editor - Motion" {
    var testapp = TestApp.create("test/test1", @src());
    defer testapp.deinit();
    const editor = testapp.editor;

    try editor.testMotion(&.{.{ .char = 'l' }}, 1, 1);
    try editor.testMotion(&.{.{ .char = 'h' }}, 0, 0);
    try editor.testMotion(&.{.{ .char = 'k' }}, 0, 0);
    try editor.testMotion(&.{.{ .char = 'j' }}, 21, 21);
    try editor.testMotion(&.{.{ .char = 'l' }}, 22, 22);
    try editor.testMotion(&.{.{ .char = 'k' }}, 1, 1);

    try editor.testMotion(&.{.{ .char = 'w' }}, 6, 6);
    try editor.testMotion(&.{.{ .char = 'w' }}, 9, 9);
    try editor.testMotion(&.{.{ .char = 'e' }}, 13, 13);
    try editor.testMotion(&.{.{ .char = 'b' }}, 9, 9);
    try editor.testMotion(&.{.{ .char = 'w' }}, 15, 15);
    try editor.testMotion(&.{.{ .char = 'w' }}, 21, 21);

    try editor.testMotion(&.{ .{ .char = 'f' }, .{ .char = '@' } }, 27, 27);
    try editor.testMotion(&.{.{ .char = '_' }}, 21, 21);
    try editor.testMotion(&.{ .{ .char = 't' }, .{ .char = '@' } }, 26, 26);
    try editor.testMotion(&.{ .{ .char = 'F' }, .{ .char = '=' } }, 25, 25);
    try editor.testMotion(&.{.{ .char = '$' }}, 41, 41);

    try editor.testMotion(&.{.{ .char = 'j' }}, 43, 43);
    try editor.testMotion(&.{.{ .char = 'j' }}, 64, 64);
    try editor.testMotion(&.{.{ .char = 'j' }}, 99, 99);
    try editor.testMotion(&.{.{ .char = 'j' }}, 146, 146);
    try editor.testMotion(&.{.{ .char = '_' }}, 130, 130);
    try editor.testMotion(&.{.{ .char = '0' }}, 126, 126);
}

test "Editor - Delete Motion" {
    var testapp = TestApp.create("test/test1", @src());
    defer testapp.deinit();
    const editor = testapp.editor;

    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = 'l' } }, 0, 0);
    try editor.testMotion(&.{.{ .char = 'j' }}, 20, 20);
    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = 'k' } }, 0, 0);

    try editor.testMotion(&.{.{ .char = 'j' }}, 1, 1);
    // try editor.testMotion(&.{.{ .char = 'w' }}, 5, 5);
    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = 'w' } }, 1, 1);
    try editor.testMotion(&.{ .{ .char = 't' }, .{ .char = 'n' } }, 1, 1);
    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = 'e' } }, 1, 1);
    try editor.testMotion(&.{ .{ .char = 't' }, .{ .char = 'b' } }, 1, 1);

    try editor.testMotion(&.{ .{ .char = 'f' }, .{ .char = '*' } }, 11, 11);
    try editor.testMotion(&.{.{ .char = 'l' }}, 12, 12);
    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = 'e' } }, 12, 12);
    try editor.testMotion(&.{ .{ .char = 't' }, .{ .char = 'B' } }, 12, 12);

    try editor.testMotion(&.{ .{ .char = 'd' }, .{ .char = '$' } }, 12, 12);
    try editor.testMotion(&.{.{ .char = '$' }}, 11, 11);
    try editor.testMotion(&.{ .{ .char = 'f' }, .{ .char = 'c' } }, 15, 15);
}

test "Editor - Delete TextObject" {
    var testapp = TestApp.create("test/test_textobject", @src());
    defer testapp.deinit();
    const editor = testapp.editor;

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = 'a' } });
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 0, 9);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 0, 9);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 0, 11);

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '~' } });
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '(' } }, 1, 8);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 1, 9);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 1, 9);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 1, 11);

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '~' } });
    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '*' } });
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 2, 9);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 2, 9);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 2, 11);

    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = ')' } }, 3, 22);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 3, 9);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 3, 9);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 3, 11);

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '~' } });
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 4, 4);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 4, 4);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 4, 6);

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '~' } });
    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = 'b' } });
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 5, 4);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 5, 4);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = '-' } }, 5, 6);

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = '~' } });
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = ')' } }, 6, 26);
    try editor.testMotionLC(&.{ .{ .char = 'f' }, .{ .char = ')' } }, 6, 30);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = '(' } }, 6, 4);
    try editor.testMotionLC(&.{ .{ .char = 'd' }, .{ .char = 'i' }, .{ .char = ')' } }, 6, 4);
}

test "Editor - Visual Motion" {
    var testapp = TestApp.create("test/test1", @src());
    defer testapp.deinit();
    const editor = testapp.editor;

    try editor.testMotion(&.{ .{ .char = 'v' }, .{ .char = 'l' } }, 0, 1);
    try editor.testMotion(&.{.{ .char = 'h' }}, 0, 0);
    try editor.testMotion(&.{.{ .char = 'k' }}, 0, 0);
    try editor.testMotion(&.{.{ .char = 'j' }}, 0, 21);
    try editor.testMotion(&.{.{ .char = 'l' }}, 0, 22);
    try editor.testMotion(&.{.{ .char = 'k' }}, 0, 1);

    try editor.testMotion(&.{.{ .char = 'w' }}, 0, 6);
    try editor.testMotion(&.{.{ .char = 'w' }}, 0, 9);
    try editor.testMotion(&.{.{ .char = 'e' }}, 0, 13);
    try editor.testMotion(&.{.{ .char = 'b' }}, 0, 9);
    try editor.testMotion(&.{.{ .char = 'w' }}, 0, 15);
    try editor.testMotion(&.{.{ .char = 'w' }}, 0, 21);

    try editor.testMotion(&.{ .{ .char = 'f' }, .{ .char = '@' } }, 0, 27);
    try editor.testMotion(&.{.{ .char = '_' }}, 0, 21);
    try editor.testMotion(&.{ .{ .char = 't' }, .{ .char = '@' } }, 0, 26);
    try editor.testMotion(&.{ .{ .char = 'F' }, .{ .char = '=' } }, 0, 25);
    try editor.testMotion(&.{.{ .char = '$' }}, 0, 41);

    try editor.testMotion(&.{.{ .char = 'j' }}, 0, 43);
    try editor.testMotion(&.{.{ .char = 'j' }}, 0, 64);
}

test "Editor - Visual Text Objects" {
    var testapp = TestApp.create("test/test_textobject", @src());
    defer testapp.deinit();
    const editor = testapp.editor;

    editor.applyEvents(&.{ .{ .char = 'f' }, .{ .char = 'a' } });
    try editor.testMotionLCSplit(&.{ .{ .char = 'v' }, .{ .char = 'i' }, .{ .char = '(' } }, 0, 9, 0, 21);
    try editor.testMotionLCSplit(&.{ .{ .char = 'i' }, .{ .char = '(' } }, 0, 9, 0, 21);
    try editor.testMotionLC(&.{.{ .key = .escape }}, 0, 21);
    editor.applyEvents(&.{ .{ .char = 'v' }, .{ .char = 'h' } });
    try editor.testMotionLCSplit(&.{ .{ .char = 'i' }, .{ .char = '(' } }, 0, 21, 0, 9);
    try editor.testMotionLCSplit(&.{ .{ .char = 'i' }, .{ .char = '(' } }, 0, 21, 0, 9);
    try editor.testMotionLC(&.{.{ .key = .escape }}, 0, 9);

    try editor.testMotionLC(&.{ .{ .char = '0' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' }, .{ .char = 'j' } }, 8, 0);
    try editor.testMotionLCSplit(&.{ .{ .char = 'v' }, .{ .char = 'i' }, .{ .char = '{' } }, 9, 0, 9, 9);
    try editor.testMotionLC(&.{.{ .key = .escape }}, 9, 9);
    try editor.testMotionLCSplit(&.{ .{ .char = 'v' }, .{ .char = 'i' }, .{ .char = '{' } }, 9, 0, 9, 9);
}
