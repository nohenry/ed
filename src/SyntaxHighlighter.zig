const std = @import("std");
const ed = @import("ed.zig");
const lang = @import("language.zig");
const Self = @This();

const buffer_len = 16;
const buffer_mask = buffer_len - 1;

tokenizer: lang.Tokenizer,

ring_buffer: [buffer_len]lang.Token = undefined,
head: usize = 0,
peeked: usize = 0,
tail: usize = 0,

pub fn init(tokenizer: lang.Tokenizer) Self {
    return .{
        .tokenizer = tokenizer,
    };
}

// t1 t2 t3 t4 t5 t6
// ^p
// ^h
// ^t
//
// peek:
// t1 t2 t3 t4 t5 t6
//    ^p
// ^h
// ^t

pub fn nextHighlight(self: *Self, rope: *ed.Rope, keyword_buffer: *std.ArrayList(u8), scratch: std.mem.Allocator) ?struct { lang.Token, ed.Color } {
    var token = self.peek(0) orelse return null;
    defer self.consume();

    if (token.tag == .identifier) {
        rope.toOwnedSliceArrayList(token.loc.start, token.loc.end, keyword_buffer, scratch);
        if (lang.Token.getKeyword(keyword_buffer.items)) |kw| {
            token = .{ .tag = kw, .loc = token.loc };
        }
    }

    const color = switch (token.tag) {
        .eof => return null,
        .invalid => ed.Color.init(255, 255, 255),
        .invalid_periodasterisks,
        .bang,
        .pipe,
        .pipe_pipe,
        .pipe_equal,
        .equal,
        .equal_equal,
        .equal_angle_bracket_right,
        .bang_equal,
        .l_paren,
        .r_paren,
        .semicolon,
        .percent,
        .percent_equal,
        .l_brace,
        .r_brace,
        .l_bracket,
        .r_bracket,
        .period,
        .period_asterisk,
        .ellipsis2,
        .ellipsis3,
        .caret,
        .caret_equal,
        .plus,
        .plus_plus,
        .plus_equal,
        .plus_percent,
        .plus_percent_equal,
        .plus_pipe,
        .plus_pipe_equal,
        .minus,
        .minus_equal,
        .minus_percent,
        .minus_percent_equal,
        .minus_pipe,
        .minus_pipe_equal,
        .asterisk,
        .asterisk_equal,
        .asterisk_asterisk,
        .asterisk_percent,
        .asterisk_percent_equal,
        .asterisk_pipe,
        .asterisk_pipe_equal,
        .arrow,
        .colon,
        .slash,
        .slash_equal,
        .comma,
        .ampersand,
        .ampersand_equal,
        .question_mark,
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .angle_bracket_angle_bracket_right,
        .angle_bracket_angle_bracket_right_equal,
        .tilde,
        => Highlight.default,

        .identifier => blk: {
            //std.debug.print("ident: {}\n", .{token});
            if (self.peek(1)) |peeked| {
                //std.debug.print("  peeked: {}\n", .{peeked});
                if (peeked.tag == .l_paren) {
                    break :blk Highlight.function;
                }
            }
            switch (keyword_buffer.items[0]) {
                'A'...'Z' => break :blk Highlight.type_,
                else => {},
            }
            if (self.peekBack(1)) |peeked| {
                //std.debug.print("  peekedBack: {}\n", .{peeked});
                if (peeked.tag == .period) {
                    break :blk Highlight.member;
                }
            }
            break :blk Highlight.default;
        },
        .builtin => Highlight.builtin,

        .string_literal,
        .multiline_string_literal_line,
        .char_literal,
        => Highlight.string,

        .number_literal => Highlight.number,

        .line_comment,
        .doc_comment,
        .container_doc_comment,
        => Highlight.comment,

        .keyword_and,
        .keyword_break,
        .keyword_catch,
        .keyword_defer,
        .keyword_else,
        .keyword_continue,
        .keyword_for,
        .keyword_if,
        .keyword_or,
        .keyword_orelse,
        .keyword_return,
        .keyword_switch,
        .keyword_try,
        .keyword_while,
        .keyword_unreachable,
        .keyword_usingnamespace,
        .keyword_export,
        .keyword_errdefer,
        => Highlight.keyword_control_flow,

        .keyword_error,
        .keyword_const,
        .keyword_var,
        .keyword_struct,
        .keyword_union,
        .keyword_enum,
        .keyword_threadlocal,
        .keyword_volatile,
        .keyword_opaque,
        .keyword_allowzero,
        .keyword_noalias,
        .keyword_inline,
        .keyword_noinline,
        .keyword_nosuspend,
        .keyword_comptime,
        .keyword_extern,
        .keyword_packed,
        .keyword_pub,
        .keyword_linksection,
        .keyword_callconv,
        .keyword_align,
        .keyword_addrspace,
        => Highlight.keyword_storage,

        .keyword_asm,
        .keyword_fn,
        .keyword_resume,
        .keyword_suspend,
        .keyword_test,
        => Highlight.keyword,

        .keyword_anyframe,
        .keyword_anytype,
        => Highlight.type_,
    };

    return .{ token, color };
}

pub fn peek(self: *Self, n: usize) ?lang.Token {
    while (self.peeked < (self.head + n + 1)) : (self.peeked += 1) {
        // If peeking wraps over trail, we consume and increment tail
        if ((self.peeked) & buffer_mask < (self.head & buffer_mask) and
            ((self.peeked) & buffer_mask) == (self.tail & buffer_mask))
        {
            self.tail += 1;
        }

        self.ring_buffer[self.peeked & buffer_mask] = self.tokenizer.next();
    }

    if (self.peeked < (self.head + n + 1)) {
        return null;
    } else {
        return self.ring_buffer[(self.head + n) & buffer_mask];
    }
}

pub fn peekBack(self: *Self, n: usize) ?lang.Token {
    if (self.tail + n > self.head) {
        return null;
    }
    return self.ring_buffer[(self.head - n) & buffer_mask];
}

pub fn consume(self: *Self) void {
    if (self.head < self.peeked) {
        self.head += 1;
        if ((self.peeked & buffer_mask) == (self.tail & buffer_mask)) {
            self.tail += 1;
        }
    } else {
        _ = self.tokenizer.next();
        self.head += 1;
        self.peeked += 1;

        if ((self.head & buffer_mask) == (self.tail & buffer_mask)) {
            self.tail += 1;
        }
    }
}

fn expect(token: ?lang.Token, tag: lang.Token.Tag, start: usize, end: usize) !void {
    try std.testing.expect(token != null);

    try std.testing.expectEqual(tag, token.?.tag);
    try std.testing.expectEqual(start, token.?.loc.start);
    try std.testing.expectEqual(end, token.?.loc.end);
}

test "Syntax Highlighter - Ring Buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rope = ed.Rope.init(arena.allocator());
    rope.loadString("pub const foobar = {}; noinline + - / * ; [ ] & | !");

    const tokenizer = lang.Tokenizer.init(&rope);
    var highlighter = Self.init(tokenizer);

    try expect(highlighter.peek(0), .identifier, 0, 3);
    try expect(highlighter.peek(0), .identifier, 0, 3);
    try expect(highlighter.peek(0), .identifier, 0, 3);
    try expect(highlighter.peek(1), .identifier, 4, 9);
    highlighter.consume();
    try expect(highlighter.peek(0), .identifier, 4, 9);
    try expect(highlighter.peekBack(1), .identifier, 0, 3);
    try std.testing.expectEqual(highlighter.peekBack(2), null);
    try expect(highlighter.peek(13), .r_bracket, 44, 45);
    try expect(highlighter.peek(14), .ampersand, 46, 47);
    try std.testing.expectEqual(highlighter.peek(15), null);
    try expect(highlighter.peek(13), .r_bracket, 44, 45);
    try expect(highlighter.peek(14), .ampersand, 46, 47);
    highlighter.consume();
    try expect(highlighter.peek(0), .identifier, 10, 16);
}

pub const Highlight = struct {
    pub const default = white;
    pub const comment = light_gray;
    pub const keyword = red;
    pub const keyword_control_flow = purple;
    pub const keyword_storage = purple;
    pub const string = green;
    pub const number = gold;
    pub const builtin = red;
    pub const function = blue;
    pub const member = red;
    pub const type_ = yellow;

    pub const yellow = ed.Color.initHex("#E5C07B");
    pub const blue = ed.Color.initHex("#61AFEF");
    pub const red = ed.Color.initHex("#E06C75");
    pub const purple = ed.Color.initHex("#C678DD");
    pub const green = ed.Color.initHex("#98C379");
    pub const gold = ed.Color.initHex("#D19A66");
    pub const cyan = ed.Color.initHex("#56B6C2");
    pub const white = ed.Color.initHex("#ABB2BF");
    pub const black = ed.Color.initHex("#282C34");
    pub const light_black = ed.Color.initHex("#2C323C");
    pub const gray = ed.Color.initHex("#3E4452");
    pub const faint_gray = ed.Color.initHex("#3B4048");
    pub const light_gray = ed.Color.initHex("#5C6370");
};

pub fn syntax_highlight(token: lang.Token) ed.Color {
    return switch (token.tag) {
        .invalid => ed.Color.init(255, 255, 255),
        .invalid_periodasterisks,
        .bang,
        .pipe,
        .pipe_pipe,
        .pipe_equal,
        .equal,
        .equal_equal,
        .equal_angle_bracket_right,
        .bang_equal,
        .l_paren,
        .r_paren,
        .semicolon,
        .percent,
        .percent_equal,
        .l_brace,
        .r_brace,
        .l_bracket,
        .r_bracket,
        .period,
        .period_asterisk,
        .ellipsis2,
        .ellipsis3,
        .caret,
        .caret_equal,
        .plus,
        .plus_plus,
        .plus_equal,
        .plus_percent,
        .plus_percent_equal,
        .plus_pipe,
        .plus_pipe_equal,
        .minus,
        .minus_equal,
        .minus_percent,
        .minus_percent_equal,
        .minus_pipe,
        .minus_pipe_equal,
        .asterisk,
        .asterisk_equal,
        .asterisk_asterisk,
        .asterisk_percent,
        .asterisk_percent_equal,
        .asterisk_pipe,
        .asterisk_pipe_equal,
        .arrow,
        .colon,
        .slash,
        .slash_equal,
        .comma,
        .ampersand,
        .ampersand_equal,
        .question_mark,
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .angle_bracket_angle_bracket_right,
        .angle_bracket_angle_bracket_right_equal,
        .tilde,
        .eof,
        => Highlight.default,

        .identifier => Highlight.default,
        .builtin => Highlight.builtin,

        .string_literal,
        .multiline_string_literal_line,
        .char_literal,
        => Highlight.string,

        .number_literal => Highlight.number,

        .line_comment,
        .doc_comment,
        .container_doc_comment,
        => Highlight.comment,

        .keyword_and,
        .keyword_break,
        .keyword_catch,
        .keyword_defer,
        .keyword_else,
        .keyword_continue,
        .keyword_for,
        .keyword_if,
        .keyword_or,
        .keyword_orelse,
        .keyword_return,
        .keyword_switch,
        .keyword_try,
        .keyword_while,
        .keyword_unreachable,
        .keyword_usingnamespace,
        .keyword_export,
        .keyword_errdefer,
        => Highlight.keyword_control_flow,

        .keyword_error,
        .keyword_const,
        .keyword_var,
        .keyword_struct,
        .keyword_union,
        .keyword_enum,
        .keyword_threadlocal,
        .keyword_volatile,
        .keyword_opaque,
        .keyword_allowzero,
        .keyword_noalias,
        .keyword_inline,
        .keyword_noinline,
        .keyword_nosuspend,
        .keyword_comptime,
        .keyword_extern,
        .keyword_packed,
        .keyword_pub,
        .keyword_linksection,
        .keyword_callconv,
        .keyword_align,
        .keyword_addrspace,
        => Highlight.keyword_storage,

        .keyword_asm,
        .keyword_fn,
        .keyword_resume,
        .keyword_suspend,
        .keyword_test,
        => Highlight.keyword,

        .keyword_anyframe,
        .keyword_anytype,
        => Highlight.type_,
    };
}
