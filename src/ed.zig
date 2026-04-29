pub const Document = @import("Document.zig");
pub const View = @import("View.zig");
pub const Rope = @import("Rope.zig");

pub const Renderer = @import("directx/directx.zig").Renderer;

comptime {
    _ = Rope;
}

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
