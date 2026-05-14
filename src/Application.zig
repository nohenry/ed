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
            const msg: WindowMessage = @enumFromInt(message);
            if (false) {
                switch (msg) {
                    .WM_NCHITTEST,
                    .WM_SETCURSOR,
                    .WM_NCMOUSEMOVE,
                    .WM_MOUSEMOVE,
                    .WM_MOVE,
                    .WM_MOVING,
                    .WM_WINDOWPOSCHANGED,
                    .WM_GETMINMAXINFO,
                    .WM_WINDOWPOSCHANGING,
                    => {},
                    else => {
                        std.debug.print("window message: {t} {} {}\n", .{ msg, wparam, lparam });
                    },
                    _ => {
                        std.debug.print("window message: {} {} {}\n", .{ message, wparam, lparam });
                    },
                }
            }
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
                win32.WM_DISPLAYCHANGE => {
                    // @Robustness: i had an issue where after my display went to sleep, then woke up, the surface
                    //              was offset into the top left corner. Calling ResizeBuffers didn't do anything,
                    //              but this seems to work. Not sure if this is the right thing to do, or if this is
                    //              the right window message it should be done in.
                    _ = win32.UpdateWindow(hwnd);
                },
                win32.WM_SYSCOMMAND => {
                    // this prevents Alt commands from beeping
                    if (wparam == win32.SC_KEYMENU) {
                        return 0;
                    }
                },
                win32.WM_INITMENU, win32.WM_MENUCHAR, win32.WM_ENTERMENULOOP => return 0,
                win32.WM_SYSKEYDOWN, win32.WM_KEYDOWN => {
                    const create_key = struct {
                        pub fn create(key: ed.Key) ed.Event {
                            return .{
                                .key_down = .{
                                    .key = key,
                                    .char = 0,
                                    .modifers = .{
                                        .ctrl = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_CONTROL))) & 0x8000 > 0) 1 else 0,
                                        // .shift = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_SHIFT))) & 0x8000 > 0) 1 else 0,
                                        .shift = 0,
                                        .alt = if (@as(u16, @bitCast(win32.GetKeyState(win32.VK_MENU))) & 0x8000 > 0) 1 else 0,
                                    },
                                },
                            };
                        }
                    }.create;
                    const event: ?ed.Event = switch (wparam) {
                        win32.VK_ESCAPE => create_key(.escape),
                        win32.VK_BACK => create_key(.backspace),
                        win32.VK_RETURN => create_key(.enter),
                        win32.VK_LEFT => create_key(.left),
                        win32.VK_RIGHT => create_key(.right),
                        win32.VK_UP => create_key(.up),
                        win32.VK_DOWN => create_key(.down),
                        win32.VK_HOME => create_key(.home),
                        win32.VK_END => create_key(.end),
                        win32.VK_NAVIGATION_UP => create_key(.page_up),
                        win32.VK_NAVIGATION_DOWN => create_key(.page_down),
                        win32.VK_TAB => create_key(.tab),
                        win32.VK_DELETE => create_key(.delete),
                        win32.VK_INSERT => create_key(.insert),
                        win32.VK_SCROLL => create_key(.scroll_lock),
                        win32.VK_NUMLOCK => create_key(.num_lock),
                        win32.VK_PRINT => create_key(.print_screen),
                        win32.VK_PAUSE => create_key(.pause),
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

pub fn force_resize(self: *Application, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
    self.renderer.force_resize(width, height);
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

pub const WindowMessage = enum(u32) {
    WM_NULL = 0x0000,
    WM_CREATE = 0x0001,
    WM_DESTROY = 0x0002,
    WM_MOVE = 0x0003,
    WM_SIZE = 0x0005,
    WM_ACTIVATE = 0x0006,
    WM_SETFOCUS = 0x0007,
    WM_KILLFOCUS = 0x0008,
    WM_ENABLE = 0x000A,
    WM_SETREDRAW = 0x000B,
    WM_SETTEXT = 0x000C,
    WM_GETTEXT = 0x000D,
    WM_GETTEXTLENGTH = 0x000E,
    WM_PAINT = 0x000F,
    WM_CLOSE = 0x0010,
    WM_QUERYENDSESSION = 0x0011,
    WM_QUERYOPEN = 0x0013,
    WM_ENDSESSION = 0x0016,
    WM_QUIT = 0x0012,
    WM_ERASEBKGND = 0x0014,
    WM_SYSCOLORCHANGE = 0x0015,
    WM_SHOWWINDOW = 0x0018,
    WM_WININICHANGE = 0x001A,
    WM_DEVMODECHANGE = 0x001B,
    WM_ACTIVATEAPP = 0x001C,
    WM_FONTCHANGE = 0x001D,
    WM_TIMECHANGE = 0x001E,
    WM_CANCELMODE = 0x001F,
    WM_SETCURSOR = 0x0020,
    WM_MOUSEACTIVATE = 0x0021,
    WM_CHILDACTIVATE = 0x0022,
    WM_QUEUESYNC = 0x0023,
    WM_GETMINMAXINFO = 0x0024,
    WM_PAINTICON = 0x0026,
    WM_ICONERASEBKGND = 0x0027,
    WM_NEXTDLGCTL = 0x0028,
    WM_SPOOLERSTATUS = 0x002A,
    WM_DRAWITEM = 0x002B,
    WM_MEASUREITEM = 0x002C,
    WM_DELETEITEM = 0x002D,
    WM_VKEYTOITEM = 0x002E,
    WM_CHARTOITEM = 0x002F,
    WM_SETFONT = 0x0030,
    WM_GETFONT = 0x0031,
    WM_SETHOTKEY = 0x0032,
    WM_GETHOTKEY = 0x0033,
    WM_QUERYDRAGICON = 0x0037,
    WM_COMPAREITEM = 0x0039,
    WM_GETOBJECT = 0x003D,
    WM_COMPACTING = 0x0041,
    WM_COMMNOTIFY = 0x0044,
    WM_WINDOWPOSCHANGING = 0x0046,
    WM_WINDOWPOSCHANGED = 0x0047,
    WM_POWER = 0x0048,
    WM_COPYDATA = 0x004A,
    WM_CANCELJOURNAL = 0x004B,
    WM_NOTIFY = 0x004E,
    WM_INPUTLANGCHANGEREQUEST = 0x0050,
    WM_INPUTLANGCHANGE = 0x0051,
    WM_TCARD = 0x0052,
    WM_HELP = 0x0053,
    WM_USERCHANGED = 0x0054,
    WM_NOTIFYFORMAT = 0x0055,
    WM_CONTEXTMENU = 0x007B,
    WM_STYLECHANGING = 0x007C,
    WM_STYLECHANGED = 0x007D,
    WM_DISPLAYCHANGE = 0x007E,
    WM_GETICON = 0x007F,
    WM_SETICON = 0x0080,
    WM_NCCREATE = 0x0081,
    WM_NCDESTROY = 0x0082,
    WM_NCCALCSIZE = 0x0083,
    WM_NCHITTEST = 0x0084,
    WM_NCPAINT = 0x0085,
    WM_NCACTIVATE = 0x0086,
    WM_GETDLGCODE = 0x0087,
    WM_SYNCPAINT = 0x0088,
    WM_NCMOUSEMOVE = 0x00A0,
    WM_NCLBUTTONDOWN = 0x00A1,
    WM_NCLBUTTONUP = 0x00A2,
    WM_NCLBUTTONDBLCLK = 0x00A3,
    WM_NCRBUTTONDOWN = 0x00A4,
    WM_NCRBUTTONUP = 0x00A5,
    WM_NCRBUTTONDBLCLK = 0x00A6,
    WM_NCMBUTTONDOWN = 0x00A7,
    WM_NCMBUTTONUP = 0x00A8,
    WM_NCMBUTTONDBLCLK = 0x00A9,
    WM_NCXBUTTONDOWN = 0x00AB,
    WM_NCXBUTTONUP = 0x00AC,
    WM_NCXBUTTONDBLCLK = 0x00AD,
    WM_INPUT_DEVICE_CHANGE = 0x00FE,
    WM_INPUT = 0x00FF,
    WM_KEYDOWN = 0x0100,
    WM_KEYUP = 0x0101,
    WM_CHAR = 0x0102,
    WM_DEADCHAR = 0x0103,
    WM_SYSKEYDOWN = 0x0104,
    WM_SYSKEYUP = 0x0105,
    WM_SYSCHAR = 0x0106,
    WM_SYSDEADCHAR = 0x0107,
    WM_UNICHAR = 0x0109,
    WM_KEYLAST2 = 0x0108,
    WM_IME_STARTCOMPOSITION = 0x010D,
    WM_IME_ENDCOMPOSITION = 0x010E,
    WM_IME_COMPOSITION = 0x010F,
    WM_INITDIALOG = 0x0110,
    WM_COMMAND = 0x0111,
    WM_SYSCOMMAND = 0x0112,
    WM_TIMER = 0x0113,
    WM_HSCROLL = 0x0114,
    WM_VSCROLL = 0x0115,
    WM_INITMENU = 0x0116,
    WM_INITMENUPOPUP = 0x0117,
    WM_GESTURE = 0x0119,
    WM_GESTURENOTIFY = 0x011A,
    WM_MENUSELECT = 0x011F,
    WM_MENUCHAR = 0x0120,
    WM_ENTERIDLE = 0x0121,
    WM_MENURBUTTONUP = 0x0122,
    WM_MENUDRAG = 0x0123,
    WM_MENUGETOBJECT = 0x0124,
    WM_UNINITMENUPOPUP = 0x0125,
    WM_MENUCOMMAND = 0x0126,
    WM_CHANGEUISTATE = 0x0127,
    WM_UPDATEUISTATE = 0x0128,
    WM_QUERYUISTATE = 0x0129,
    WM_CTLCOLORMSGBOX = 0x0132,
    WM_CTLCOLOREDIT = 0x0133,
    WM_CTLCOLORLISTBOX = 0x0134,
    WM_CTLCOLORBTN = 0x0135,
    WM_CTLCOLORDLG = 0x0136,
    WM_CTLCOLORSCROLLBAR = 0x0137,
    WM_CTLCOLORSTATIC = 0x0138,
    WM_MOUSEMOVE = 0x0200,
    WM_LBUTTONDOWN = 0x0201,
    WM_LBUTTONUP = 0x0202,
    WM_LBUTTONDBLCLK = 0x0203,
    WM_RBUTTONDOWN = 0x0204,
    WM_RBUTTONUP = 0x0205,
    WM_RBUTTONDBLCLK = 0x0206,
    WM_MBUTTONDOWN = 0x0207,
    WM_MBUTTONUP = 0x0208,
    WM_MBUTTONDBLCLK = 0x0209,
    WM_MOUSEWHEEL = 0x020A,
    WM_XBUTTONDOWN = 0x020B,
    WM_XBUTTONUP = 0x020C,
    WM_XBUTTONDBLCLK = 0x020D,
    WM_MOUSEHWHEEL = 0x020E,
    WM_PARENTNOTIFY = 0x0210,
    WM_ENTERMENULOOP = 0x0211,
    WM_EXITMENULOOP = 0x0212,
    WM_NEXTMENU = 0x0213,
    WM_SIZING = 0x0214,
    WM_CAPTURECHANGED = 0x0215,
    WM_MOVING = 0x0216,
    WM_POWERBROADCAST = 0x0218,
    WM_DEVICECHANGE = 0x0219,
    WM_MDICREATE = 0x0220,
    WM_MDIDESTROY = 0x0221,
    WM_MDIACTIVATE = 0x0222,
    WM_MDIRESTORE = 0x0223,
    WM_MDINEXT = 0x0224,
    WM_MDIMAXIMIZE = 0x0225,
    WM_MDITILE = 0x0226,
    WM_MDICASCADE = 0x0227,
    WM_MDIICONARRANGE = 0x0228,
    WM_MDIGETACTIVE = 0x0229,
    WM_MDISETMENU = 0x0230,
    WM_ENTERSIZEMOVE = 0x0231,
    WM_EXITSIZEMOVE = 0x0232,
    WM_DROPFILES = 0x0233,
    WM_MDIREFRESHMENU = 0x0234,
    WM_POINTERDEVICECHANGE = 0x238,
    WM_POINTERDEVICEINRANGE = 0x239,
    WM_POINTERDEVICEOUTOFRANGE = 0x23A,
    WM_TOUCH = 0x0240,
    WM_NCPOINTERUPDATE = 0x0241,
    WM_NCPOINTERDOWN = 0x0242,
    WM_NCPOINTERUP = 0x0243,
    WM_POINTERUPDATE = 0x0245,
    WM_POINTERDOWN = 0x0246,
    WM_POINTERUP = 0x0247,
    WM_POINTERENTER = 0x0249,
    WM_POINTERLEAVE = 0x024A,
    WM_POINTERACTIVATE = 0x024B,
    WM_POINTERCAPTURECHANGED = 0x024C,
    WM_TOUCHHITTESTING = 0x024D,
    WM_POINTERWHEEL = 0x024E,
    WM_POINTERHWHEEL = 0x024F,
    WM_POINTERROUTEDTO = 0x0251,
    WM_POINTERROUTEDAWAY = 0x0252,
    WM_POINTERROUTEDRELEASED = 0x0253,
    WM_IME_SETCONTEXT = 0x0281,
    WM_IME_NOTIFY = 0x0282,
    WM_IME_CONTROL = 0x0283,
    WM_IME_COMPOSITIONFULL = 0x0284,
    WM_IME_SELECT = 0x0285,
    WM_IME_CHAR = 0x0286,
    WM_IME_REQUEST = 0x0288,
    WM_IME_KEYDOWN = 0x0290,
    WM_IME_KEYUP = 0x0291,
    WM_MOUSEHOVER = 0x02A1,
    WM_MOUSELEAVE = 0x02A3,
    WM_NCMOUSEHOVER = 0x02A0,
    WM_NCMOUSELEAVE = 0x02A2,
    WM_WTSSESSION_CHANGE = 0x02B1,
    WM_TABLET_FIRST = 0x02c0,
    WM_TABLET_LAST = 0x02df,
    WM_DPICHANGED = 0x02E0,
    WM_DPICHANGED_BEFOREPARENT = 0x02E2,
    WM_DPICHANGED_AFTERPARENT = 0x02E3,
    WM_GETDPISCALEDSIZE = 0x02E4,
    WM_CUT = 0x0300,
    WM_COPY = 0x0301,
    WM_PASTE = 0x0302,
    WM_CLEAR = 0x0303,
    WM_UNDO = 0x0304,
    WM_RENDERFORMAT = 0x0305,
    WM_RENDERALLFORMATS = 0x0306,
    WM_DESTROYCLIPBOARD = 0x0307,
    WM_DRAWCLIPBOARD = 0x0308,
    WM_PAINTCLIPBOARD = 0x0309,
    WM_VSCROLLCLIPBOARD = 0x030A,
    WM_SIZECLIPBOARD = 0x030B,
    WM_ASKCBFORMATNAME = 0x030C,
    WM_CHANGECBCHAIN = 0x030D,
    WM_HSCROLLCLIPBOARD = 0x030E,
    WM_QUERYNEWPALETTE = 0x030F,
    WM_PALETTEISCHANGING = 0x0310,
    WM_PALETTECHANGED = 0x0311,
    WM_HOTKEY = 0x0312,
    WM_PRINT = 0x0317,
    WM_PRINTCLIENT = 0x0318,
    WM_APPCOMMAND = 0x0319,
    WM_THEMECHANGED = 0x031A,
    WM_CLIPBOARDUPDATE = 0x031D,
    WM_DWMCOMPOSITIONCHANGED = 0x031E,
    WM_DWMNCRENDERINGCHANGED = 0x031F,
    WM_DWMCOLORIZATIONCOLORCHANGED = 0x0320,
    WM_DWMWINDOWMAXIMIZEDCHANGE = 0x0321,
    WM_DWMSENDICONICTHUMBNAIL = 0x0323,
    WM_DWMSENDICONICLIVEPREVIEWBITMAP = 0x0326,
    WM_GETTITLEBARINFOEX = 0x033F,
    WM_HANDHELDFIRST = 0x0358,
    WM_HANDHELDLAST = 0x035F,
    WM_AFXFIRST = 0x0360,
    WM_AFXLAST = 0x037F,
    WM_PENWINFIRST = 0x0380,
    WM_PENWINLAST = 0x038F,
    WM_APP = 0x8000,
    WM_USER = 0x0400,
    WM_INTERCEPTED_WINDOW_ACTION = 0x0346,
    WM_TOOLTIPDISMISS = 0x0345,
    WM_CLOAKED_STATE_CHANGED = 0x0347,
    _,
};
