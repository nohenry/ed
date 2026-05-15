const std = @import("std");
pub const Document = @import("Document.zig");
pub const View = @import("View.zig");
pub const Rope = @import("Rope.zig");
pub const Editor = @import("Editor.zig");
pub const Pattern = @import("pattern.zig").Pattern;
pub const Application = @import("Application.zig");
pub const SyntaxHighlighter = @import("SyntaxHighlighter.zig");

pub const Renderer = @import("directx/directx.zig").Renderer;

comptime {
    _ = Rope;
    _ = Editor;
    _ = SyntaxHighlighter;
}

pub const TextObject = enum {
    word,
    WORD,
    paren,
    bracket,
    brace,
    double_quote,
    single_quote,
    backtick,

    pub inline fn fromChar(char: u32) ?TextObject {
        return switch (char) {
            'w' => .word,
            'W' => .WORD,
            '(' => .paren,
            ')' => .paren,
            '[' => .bracket,
            ']' => .bracket,
            '{' => .brace,
            '}' => .brace,
            '"' => .double_quote,
            '\'' => .single_quote,
            '`' => .backtick,
            else => null,
        };
    }

    pub inline fn getOpen(comptime self: TextObject) u8 {
        return switch (self) {
            .paren => '(',
            .bracket => '[',
            .brace => '{',
            else => unreachable,
        };
    }

    pub inline fn getClose(comptime self: TextObject) u8 {
        return switch (self) {
            .paren => ')',
            .bracket => ']',
            .brace => '}',
            else => unreachable,
        };
    }

    pub inline fn computeLevel(comptime self: TextObject, char: u8, level: *i32) void {
        switch (self) {
            .word => {},
            .WORD => {},
            .paren => switch (char) {
                '(' => level.* += 1,
                ')' => level.* -= 1,
                else => {},
            },
            .bracket => switch (char) {
                '[' => level.* += 1,
                ']' => level.* -= 1,
                else => {},
            },
            .brace => switch (char) {
                '{' => level.* += 1,
                '}' => level.* -= 1,
                else => {},
            },
            .double_quote => {},
            .single_quote => {},
            .backtick => {},
        }
    }

    pub inline fn isValid(comptime self: TextObject, char: u8) bool {
        return switch (self) {
            .word => switch (char) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => true,
                else => false,
            },
            .WORD => switch (char) {
                ' ', '\n', '\r', '\t' => false,
                else => true,
            },
            .paren => switch (char) {
                '(', ')' => false,
                else => true,
            },
            .bracket => switch (char) {
                '[', ']' => false,
                else => true,
            },
            .brace => switch (char) {
                '{', '}' => false,
                else => true,
            },
            .double_quote => switch (char) {
                '"' => false,
                else => true,
            },
            .single_quote => switch (char) {
                '\'' => false,
                else => true,
            },
            .backtick => switch (char) {
                '`' => false,
                else => true,
            },
        };
    }
};

pub const Key = enum {
    char,
    escape,
    backspace,
    enter,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    tab,
    delete,
    insert,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
};
pub const KeyModifiers = packed struct(u3) {
    ctrl: u1 = 0,
    shift: u1 = 0,
    alt: u1 = 0,
};

pub const TimerId = enum(usize) {
    yank_highlight = 1,
    _,
};

pub const KeyDownEvent = struct {
    key: Key = .char,
    char: u32 = 0,
    modifers: KeyModifiers = .{},
};

pub const Event = union(enum) {
    key_down: KeyDownEvent,
    timer: TimerId,
};

pub const Config = struct {
    gui_font_family: []const u8 = "Consolas",
    gui_font_size: u32 = 16,
};

pub const CursorKind = enum(u32) {
    hidden = 0,
    block = 1,
    bar = 2,
    underline = 3,
};
pub const Style = struct {};
pub const UnderlineStyle = enum(u32) {
    none = 0,
    line = 1,
    curl = 2,
    dotted = 3,
    dashed = 4,
    double_line = 5,
};

pub const Rect = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,

    pub inline fn width(self: *const Rect) u32 {
        return self.right - self.left;
    }

    pub inline fn height(self: *const Rect) u32 {
        return self.bottom - self.top;
    }
};

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const red = Color.init(255, 0, 0);
    pub const green = Color.init(0, 255, 0);
    pub const white = Color.init(255, 255, 255);

    pub fn init(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn initHex(comptime hex: []const u8) Color {
        var str = hex;
        if (str.len > 0 and str[0] == '#') {
            str = str[1..];
        }
        if (str.len == 3) {
            const r = parseHexDigit(str[0]) orelse @panic("Invalid hex digit");
            const g = parseHexDigit(str[1]) orelse @panic("Invalid hex digit");
            const b = parseHexDigit(str[2]) orelse @panic("Invalid hex digit");
            return .{ .r = r + r * 16, .g = g + g * 16, .b = b + b * 16, .a = 255 };
        } else if (str.len == 6) {
            const r_hi = parseHexDigit(str[0]) orelse @panic("Invalid hex digit");
            const r_lo = parseHexDigit(str[1]) orelse @panic("Invalid hex digit");
            const g_hi = parseHexDigit(str[2]) orelse @panic("Invalid hex digit");
            const g_lo = parseHexDigit(str[3]) orelse @panic("Invalid hex digit");
            const b_hi = parseHexDigit(str[4]) orelse @panic("Invalid hex digit");
            const b_lo = parseHexDigit(str[5]) orelse @panic("Invalid hex digit");
            return .{
                .r = r_lo + r_hi * 16,
                .g = g_lo + g_hi * 16,
                .b = b_lo + b_hi * 16,
                .a = 255,
            };
        } else {
            @panic("Invalid hex literal");
        }
    }

    fn parseHexDigit(digit: u8) ?u8 {
        return switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 0xa,
            'A'...'F' => digit - 'A' + 0xa,
            else => null,
        };
    }

    pub fn toPacked(self: Color) u32 {
        return @bitCast(self);
    }
};
