pub const Document = @import("Document.zig");
pub const View = @import("View.zig");
pub const Rope = @import("Rope.zig");
pub const Editor = @import("Editor.zig");
pub const Pattern = @import("pattern.zig").Pattern;

pub const Renderer = @import("directx/directx.zig").Renderer;

comptime {
    _ = Rope;
}

pub const Key = enum {
    char,
    escape,
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

pub const Event = union(enum) {
    key_down: struct {
        key: Key,
        char: u32 = 0,
        modifers: KeyModifiers,
    },
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

    pub fn toPacked(self: Color) u32 {
        return @bitCast(self);
    }
};
