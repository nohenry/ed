const std = @import("std");
const ed = @import("ed.zig");
const Self = @This();

pub const Id = struct {
    value: u32,

    pub const nil = Id{ .value = 0 };

    pub inline fn isValid(self: Id) bool {
        return self.value != 0;
    }

    pub inline fn isNil(self: Id) bool {
        return self.value == 0;
    }

    pub inline fn increment(self: Id) Id {
        return .{ .value = self.value + 1 };
    }
};

arena: std.heap.ArenaAllocator,
absolute_path: []const u8,
rope: ed.Rope,

pub fn load(self: *Self, io: std.Io, path: []const u8) void {
    self.arena = .init(std.heap.page_allocator);
    const absolute_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, self.arena.allocator()) catch @panic("Unable to find filepath");
    self.absolute_path = absolute_path;
    self.rope = .init(self.arena.allocator());

    var file = std.Io.Dir.openFileAbsolute(io, absolute_path, .{ .mode = .read_only }) catch @panic("unable to open file");
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    const file_contents = file_reader.interface.allocRemaining(self.arena.allocator(), .unlimited) catch @panic("error reading file");

    self.rope.loadString(file_contents);
}
