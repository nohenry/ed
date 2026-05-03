const std = @import("std");
const Io = std.Io;

const editor = @import("editor");

const win32 = @import("win32");

const directx = @import("directx/directx.zig");
const ed = @import("ed.zig");

comptime {
    _ = ed;
}

fn window_proc(hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const application: ?*Application = @ptrFromInt(@as(usize, @bitCast(win32.GetWindowLongPtrA(hwnd, win32.GWLP_USERDATA))));
    switch (message) {
        win32.WM_CLOSE => {
            application.?.keep_running = false;
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_SIZE => {
            const new_height: u32 = @as(u32, @intCast(lparam >> 16));
            const new_width: u32 = @as(u32, @intCast(lparam & 0xFFFF));
            application.?.resize(new_width, new_height);
        },
        win32.WM_SIZING => {
            // const rect: *const win32.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));

            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            const new_width: u32 = @intCast(rect.right - rect.left);
            const new_height: u32 = @intCast(rect.bottom - rect.top);

            application.?.resize(new_width, new_height);
        },
        win32.WM_KEYDOWN => {
            const event: ?ed.Event = switch (wparam) {
                win32.VK_ESCAPE => .{
                    .key_down = .{
                        .key = .escape,
                        .char = 0,
                    },
                },
                else => blk: {
                    var keystate: [256]u8 = undefined;
                    _ = win32.GetKeyboardState(&keystate[0]);

                    const scancode = (lparam >> 16) & 0xFF;
                    var char: u16 = 0;
                    const conversion_result = win32.ToAscii(@truncate(wparam), @intCast(scancode), &keystate, &char, 0);

                    if (conversion_result > 0) {
                        break :blk .{
                            .key_down = .{
                                .key = .char,
                                .char = char,
                            },
                        };
                    } else break :blk null;
                },
            };

            if (event) |e| application.?.handleEvent(e);
        },
        else => {},
    }
    return win32.DefWindowProcA(hwnd, message, wparam, lparam);
}

pub const Application = struct {
    hwnd: win32.HWND = null,
    keep_running: bool = true,
    renderer: directx.Renderer = undefined,
    allocator: std.mem.Allocator = undefined,

    editor: ?*ed.Editor = null,

    pub fn initPinned(self: *Application, io: std.Io, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        const hinstance = win32.GetModuleHandleA(null);
        const class_name = "my_cool_editor_class_name";
        const window_class = win32.WNDCLASSEXA{
            .cbSize = @sizeOf(win32.WNDCLASSEXA),
            .lpfnWndProc = window_proc,
            .hInstance = hinstance,
            .hCursor = win32.LoadCursorW(null, 32512),
            .lpszClassName = class_name,
        };

        _ = win32.RegisterClassExA(&window_class);
        _ = win32.SetProcessDPIAware();

        const hwnd = win32.CreateWindowExA(
            0,
            class_name,
            "MyEditor",
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            1024,
            1000,
            null,
            null,
            hinstance,
            null,
        );
        const renderer = directx.Renderer.new(hwnd, .{});
        self.renderer = renderer;
        self.renderer.resize_if_needed(1024, 1000);
        _ = win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.createEditor(io);
        self.draw();
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        self.hwnd = hwnd;
    }

    pub fn createEditor(self: *Application, io: std.Io) void {
        self.editor = self.allocator.create(ed.Editor) catch @panic("OOM");
        self.editor.?.* = .init(io, self.allocator);
        self.editor.?.openDocument("build.zig");
    }

    pub fn resize(self: *Application, width: u32, height: u32) void {
        self.renderer.resize_if_needed(width, height);
        self.draw();
    }

    pub fn handleEvent(self: *Application, event: ed.Event) void {
        if (self.editor) |editr| {
            editr.handleEvent(event);
        }
        self.draw();
    }

    pub fn draw(self: *Application) void {
        self.renderer.start_glyph_placement();

        const area = ed.Rect{
            .left = 0,
            .top = 0,
            .right = self.renderer.cell_count_x,
            .bottom = self.renderer.cell_count_y,
        };
        if (self.editor) |editr| {
            editr.render(area, &self.renderer);
        }

        self.renderer.end_glyph_placement();
        self.renderer.draw();
    }

    pub fn run(self: *Application) void {
        while (self.keep_running) {
            const result = win32.MsgWaitForMultipleObjectsEx(0, null, @bitCast(@as(c_long, -1)), win32.QS_ALLINPUT, win32.MWMO_ALERTABLE);

            if (result == win32.WAIT_OBJECT_0) {
                var msg: win32.MSG = undefined;
                while (win32.PeekMessageA(&msg, self.hwnd, 0, 0, win32.PM_REMOVE) > 0) {
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageA(&msg);
                }
            }
        }
    }
};

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
    // rope.insertString(13, "im tthirten");

    // rope.rebalance(scratch.allocator());
    // rope.insertString(0, "foobar");
    // rope.insertString(rope.len, "fricku");

    var i = rope.iter(std.heap.page_allocator);
    while (i.next()) |f| {
        std.debug.print("char: {u}\n", .{@as(u21, @truncate(f))});
    }
    i.deinit();

    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), init.io, "output.dot", .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);

    try rope.dumpGraph(&writer.interface);
    try writer.flush();
    file.close(init.io);
}

pub fn main(init: std.process.Init) !void {
    var application: Application = .{};
    application.initPinned(init.io, init.gpa);

    application.run();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
