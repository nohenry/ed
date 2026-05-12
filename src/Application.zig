const std = @import("std");
const Io = std.Io;

const win32 = @import("win32");

const directx = @import("directx/directx.zig");
const ed = @import("ed.zig");
const pat = @import("pattern.zig");
const builtin = @import("builtin");

const Application = @This();

fn createWindowProc(comptime handleEvent_: fn (application: *Application, event: ed.Event) void) fn (hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const T = struct {
        fn windowProc(hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
            const application: ?*Application = @ptrFromInt(@as(usize, @bitCast(win32.GetWindowLongPtrA(hwnd, win32.GWLP_USERDATA))));
            switch (message) {
                win32.WM_CLOSE => {
                    application.?.keep_running = false;
                    _ = win32.DestroyWindow(hwnd);
                    return 0;
                },
                win32.WM_QUIT => {
                    application.?.keep_running = false;
                    _ = win32.DestroyWindow(hwnd);
                    return 0;
                },
                win32.WM_TIMER => {
                    handleEvent_(application.?, .{ .timer = @enumFromInt(wparam) });
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
                                .modifers = .{
                                    .ctrl = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_CONTROL))) & 0x8000 > 0) 1 else 0,
                                    // .shift = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_SHIFT))) & 0x8000 > 0) 1 else 0,
                                    .shift = 0,
                                    .alt = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_MENU))) & 0x8000 > 0) 1 else 0,
                                },
                            },
                        },
                        else => blk: {
                            var keystate: [256]u8 = undefined;
                            _ = win32.GetKeyboardState(&keystate[0]);
                            keystate[win32.VK_CONTROL] = 0;
                            // keystate[win32.VK_SHIFT] = 0;
                            keystate[win32.VK_MENU] = 0;

                            const scancode = (lparam >> 16) & 0xFF;
                            var char: u16 = 0;
                            const conversion_result = win32.ToAscii(@truncate(wparam), @intCast(scancode), &keystate, &char, 0);

                            if (conversion_result > 0) {
                                break :blk .{
                                    .key_down = .{
                                        .key = .char,
                                        .char = char,
                                        .modifers = .{
                                            .ctrl = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_CONTROL))) & 0x8000 > 0) 1 else 0,
                                            //.shift = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_SHIFT))) & 0x8000 > 0) 1 else 0,
                                            .shift = 0,
                                            .alt = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_MENU))) & 0x8000 > 0) 1 else 0,
                                        },
                                    },
                                };
                            } else break :blk null;
                        },
                    };

                    if (event) |e| {
                        handleEvent_(application.?, e);
                    }
                },
                else => {},
            }
            return win32.DefWindowProcA(hwnd, message, wparam, lparam);
        }
    };
    return T.windowProc;
}

pub const win32_applicaiton = ed.Editor.ApplicationVtable{
    .start_timer = Application.start_timer,
    .kill_timer = Application.kill_timer,
    .quit = Application.quit,
    .testing_step = Application.updateTesting,
};

hwnd: win32.HWND = null,
keep_running: bool = true,
renderer: directx.Renderer = undefined,
allocator: std.mem.Allocator = undefined,

editor: ?*ed.Editor = null,
width: u32 = 0,
height: u32 = 0,
wait_testing_step: bool = false,

pub fn start_timer(self_: *anyopaque, id: ed.TimerId, milliseconds: usize) void {
    const self: *Application = @ptrCast(@alignCast(self_));
    _ = win32.SetTimer(self.hwnd, @intFromEnum(id), @intCast(milliseconds), null);
}

pub fn kill_timer(self_: *anyopaque, id: ed.TimerId) void {
    const self: *Application = @ptrCast(@alignCast(self_));
    _ = win32.KillTimer(self.hwnd, @intFromEnum(id));
}

pub fn quit(self_: *anyopaque) void {
    const self: *Application = @ptrCast(@alignCast(self_));
    self.keep_running = false;
    win32.PostQuitMessage(0);
    std.debug.print("quit\n\n", .{});
}

pub fn createTesting(file_path: []const u8, src: std.builtin.SourceLocation) *Application {
    var application = std.testing.allocator.create(ed.Application) catch @panic("OOM");
    application.* = .{};
    application.initPinned(std.testing.io, std.testing.allocator, src.fn_name, true);

    application.createEditor(std.testing.io, file_path);
    return application;
}

pub fn createTestingFromNonTesting(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) *Application {
    var application = allocator.create(ed.Application) catch @panic("OOM");
    application.* = .{};
    application.initPinned(io, allocator, true);

    application.createEditor(io, file_path);
    return application;
}

pub fn getEditor(self: *Application) *ed.Editor {
    return self.editor.?;
}

pub fn initPinned(self: *Application, io: std.Io, allocator: std.mem.Allocator, title: []const u8, comptime testing: bool) void {
    _ = io;
    self.allocator = allocator;
    const hinstance = win32.GetModuleHandleA(null);
    const class_name = "my_cool_editor_class_name";
    const window_class = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .lpfnWndProc = if (testing) createWindowProc(handleEventTesting) else createWindowProc(handleEvent),
        .hInstance = hinstance,
        .hCursor = win32.LoadCursorW(null, 32512),
        .lpszClassName = class_name,
    };

    _ = win32.RegisterClassExA(&window_class);
    _ = win32.SetProcessDPIAware();

    const hwnd = win32.CreateWindowExA(
        0,
        class_name,
        &title[0],
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
    self.draw();
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    self.hwnd = hwnd;
}

pub fn deinit(self: *Application) void {
    if (self.editor) |e| self.allocator.destroy(e);
    if (builtin.is_test) {
        std.testing.allocator.destroy(self);
    }
}

pub fn createEditor(self: *Application, io: std.Io, file_path: []const u8) void {
    self.editor = self.allocator.create(ed.Editor) catch @panic("OOM");
    self.editor.?.* = .init(self, &win32_applicaiton, io, self.allocator);
    self.editor.?.openDocument(file_path);
    self.editor.?.resize(self.renderer.cell_count_y, self.renderer.cell_count_x);
}

pub fn resize(self: *Application, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
    self.renderer.resize_if_needed(width, height);
    if (self.editor) |e| e.resize(self.renderer.cell_count_y, self.renderer.cell_count_x);
    self.draw();
}

pub fn handleEvent(self: *Application, event: ed.Event) void {
    if (self.editor) |editr| {
        editr.handleEvent(event);
    }
    if (self.keep_running) {
        self.draw();
    }
}

pub fn handleEventTesting(self: *Application, event: ed.Event) void {
    if (event == .key_down and event.key_down.key == .char and event.key_down.char == 'n') {
        self.wait_testing_step = false;
    }
    if (self.keep_running) {
        self.draw();
    }
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
    if (self.editor) |editr| {
        editr.finish_frame();
    }
}

pub fn run(self: *Application) void {
    self.draw();
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

pub fn updateTesting(self_: *anyopaque) void {
    const self: *Application = @ptrCast(@alignCast(self_));
    self.draw();
    self.wait_testing_step = true;

    while (self.wait_testing_step) {
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
