const std = @import("std");
const Io = std.Io;

const ed = @import("ed.zig");
const pat = @import("pattern.zig");

comptime {
    _ = ed;
}

pub fn main(init: std.process.Init) !void {
    const application = ed.Application.createTestingFromNonTesting(init.io, init.arena.allocator(), "test/test1");
    defer application.deinit();
    var editor = application.getEditor();
    defer editor.quit();

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
    // var application: ed.Application = .{};
    // application.initPinned(init.io, init.gpa, false);
    // defer application.deinit();

    // application.createEditor(init.io, "test/test_textobject");
    // application.run();
}

pub fn main2(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    var rope = ed.Rope.init(arena.allocator());
    rope.loadString("what the hell are you doing");
    _ = rope.insertString(7, "1234");
    const bruhv_inser_point = rope.insertString(18, "bruhv");
    try bruhv_inser_point.appendSlice(arena.allocator(), "umm ok");
    _ = rope.insertString(13, "im tthirten");

    // rope.rebalance(scratch.allocator());
    // rope.insertString(0, "foobar");
    // rope.insertString(rope.len, "fricku");

    const pattern = ed.Pattern.parseTokenBased("the", std.heap.page_allocator);
    var matcher = rope.matchStartingFrom(pattern, 10);
    while (matcher.prev()) |s| {
        std.debug.print("matched: {}\n", .{s});
    }

    var range_iter = rope.rangeIter(4, 14);
    while (range_iter.next()) |slice| {
        std.debug.print("Range: '{s}'\n", .{slice});
    }

    // var i = rope.iter();
    // while (i.next()) |f| {
    //     std.debug.print("char: {u}\n", .{@as(u21, @truncate(f))});
    // }

    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), init.io, "output.dot", .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);

    try rope.dumpGraph(&writer.interface);
    try writer.flush();
    file.close(init.io);
}

pub fn main3() void {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const pattern = "foobar";
    const pattern1 = "foobar+";
    const pattern2 = "foobar*";
    const pattern3 = "bar+(  baz)*";
    const pattern4 = "foo (baz|bar)+b";
    _ = pattern;
    _ = pattern1;
    _ = pattern2;
    _ = pattern3;
    // _ = pattern4;
    const patternp = pat.Pattern.parseTokenBased(pattern4, allocator.allocator());
    std.debug.print("{f}\n", .{patternp});
    std.debug.print("matches {}\n", .{patternp.matches("foo bazbarbazbazbarb")});
}
