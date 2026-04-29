const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const d3d = win32;
const d2d = win32;
const dxgi = win32;
const dwrite = win32;

const compute_shader_source = @embedFile("shader.hlsl");

pub const Config = struct {
    gui_font_family: []const u8 = "Consolas",
    gui_font_size: u32 = 16,
};

pub const GlyphCache = struct {
    pub fn new_direct_codepoint_table(tile_count_x: u32) DirectCodepointTable {
        var x: u32 = 1; // Skip first cell
        var y: u32 = 0;
        var result = std.mem.zeroes(DirectCodepointTable);

        for (0..DIRECT_CODEPOINT_COUNT) |index| {
            if (x >= tile_count_x) {
                x = 0;
                y += 1;
            }

            result[index] = .init(x, y);

            x += 1;
        }

        return result;
    }
};
pub const GpuIndex = extern struct {
    x: u16,
    y: u16,
    pub inline fn init(x: u32, y: u32) GpuIndex {
        return .{ .x = @truncate(x), .y = @truncate(y) };
    }
};

pub const CELL_WIDTH = 40;
pub const CELL_HEIGHT = 100;

pub const CursorKind = enum {};
pub const Style = struct {};
pub const UnderlineStyle = enum(u32) {
    none = 0,
    line = 1,
    curl = 2,
    dotted = 3,
    dashed = 4,
    double_line = 5,
};

pub const DIRECT_CODEPOINT_MIN: u32 = 32;
pub const DIRECT_CODEPOINT_MAX: u32 = 126;
pub const DIRECT_CODEPOINT_COUNT: u32 = DIRECT_CODEPOINT_MAX - DIRECT_CODEPOINT_MIN + 1;

pub const DirectCodepointTable = [DIRECT_CODEPOINT_COUNT]GpuIndex;

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const red = Color.init(255, 0, 0);
    pub const green = Color.init(0, 255, 0);

    pub fn init(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn toPacked(self: Color) u32 {
        return @bitCast(self);
    }
};

pub inline fn set_debug_name(object: anytype, name: []const u8) void {
    _ = object.lpVtbl.*.SetPrivateData.?(
        object,
        &win32.WKPDID_D3DDebugObjectName,
        @intCast(name.len),
        name.ptr,
    );
}

const DirectxTexture = struct {
    texture: *d3d.ID3D11Texture2D,
    surface: *dxgi.IDXGISurface,
    srv: ?*d3d.ID3D11ShaderResourceView,
    uav: ?*d3d.ID3D11UnorderedAccessView,

    pub fn deinit(self: *@This()) void {
        if (self.srv) |srv| {
            srv.lpVtbl.*.Release.?(srv);
        } else {
            self.uav.?.lpVtbl.*.Release.?(self.uav.?);
        }
        self.surface.lpVtbl.*.Release.?(self.surface);
        self.texture.lpVtbl.*.Release.?(self.texture);
    }
};

const DirectxBuffer = struct {
    buffer: *d3d.ID3D11Buffer,
    srv: ?*d3d.ID3D11ShaderResourceView,
    uav: ?*d3d.ID3D11UnorderedAccessView,

    pub fn map(self: *const @This(), d3d_context: *d3d.ID3D11DeviceContext1, comptime T: type, len: usize) []T {
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = std.mem.zeroes(d3d.D3D11_MAPPED_SUBRESOURCE);
        _ = d3d_context.lpVtbl.*.Map.?(
            d3d_context,
            @ptrCast(self.buffer),
            0,
            d3d.D3D11_MAP_WRITE_NO_OVERWRITE,
            0,
            &mapped,
        );

        var result: []T = undefined;
        result.ptr = @ptrCast(@alignCast(mapped.pData));
        result.len = len;
        return result;
    }

    pub fn map_one(self: *const @This(), d3d_context: *d3d.ID3D11DeviceContext1, comptime T: type) *T {
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = std.mem.zeroes(d3d.D3D11_MAPPED_SUBRESOURCE);
        _ = d3d_context.lpVtbl.*.Map.?(
            d3d_context,
            @ptrCast(self.buffer),
            0,
            d3d.D3D11_MAP_WRITE_NO_OVERWRITE,
            0,
            &mapped,
        );
        return @ptrCast(@alignCast(mapped.pData.?));
    }

    pub fn unmap(self: *const @This(), d3d_context: *d3d.ID3D11DeviceContext1) void {
        d3d_context.lpVtbl.*.Unmap.?(d3d_context, @ptrCast(self.buffer), 0);
    }

    pub fn deinit(self: *@This()) void {
        if (self.srv) |srv| {
            _ = srv.lpVtbl.*.Release.?(srv);
        }
        if (self.uav) |uav| {
            _ = uav.lpVtbl.*.Release.?(uav);
        }
        _ = self.buffer.lpVtbl.*.Release.?(self.buffer);
    }
};

// const COMPUTE_SHADER: []const u8 = include_str!("shader.hlsl");

pub const Renderer = struct {
    hwnd: win32.HWND,
    d3d_device: *d3d.ID3D11Device,
    d3d_context: *d3d.ID3D11DeviceContext1,
    dxgi_factory: *dxgi.IDXGIFactory2,
    dxgi_swapchain: *dxgi.IDXGISwapChain2,
    dxgi_waitable_handle: win32.HANDLE,
    compute_shader: *d3d.ID3D11ComputeShader,

    uav: ?*d3d.ID3D11UnorderedAccessView,
    parameter_buffer: DirectxBuffer,
    cell_width: u32,
    cell_height: u32,
    terminal_width: u32,
    terminal_height: u32,

    cell_buffer_mapped: ?[]ScreenCell,
    cell_buffer_count: u32,
    cell_buffer: DirectxBuffer,
    cell_count_x: u32,
    cell_count_y: u32,

    glyph_renderer: GlyphRenderer,
    config: Config,

    pub fn new(hwnd: win32.HWND, config: Config) Renderer {
        var flags: c_uint = d3d.D3D11_CREATE_DEVICE_BGRA_SUPPORT | d3d.D3D11_CREATE_DEVICE_SINGLETHREADED;
        if (builtin.mode == .Debug) {
            flags |= d3d.D3D11_CREATE_DEVICE_DEBUG;
        }

        const feature_levels = [_]c_uint{ d3d.D3D_FEATURE_LEVEL_11_1, d3d.D3D_FEATURE_LEVEL_11_0 };

        // var renderer: Renderer = std.mem.zeroes(Renderer);

        var d3d_device: *d3d.ID3D11Device = undefined;
        var d3d_context: *d3d.ID3D11DeviceContext = undefined;
        var d3d_context1: *d3d.ID3D11DeviceContext1 = undefined;

        if (failed(win32.D3D11CreateDevice(
            null,
            d3d.D3D_DRIVER_TYPE_HARDWARE,
            null,
            flags,
            &feature_levels[0],
            feature_levels.len,
            d3d.D3D11_SDK_VERSION,
            @ptrCast(&d3d_device),
            null,
            @ptrCast(&d3d_context),
        ))) {
            if (failed(d3d.D3D11CreateDevice(
                null,
                d3d.D3D_DRIVER_TYPE_WARP,
                null,
                flags,
                &feature_levels[0],
                feature_levels.len,
                d3d.D3D11_SDK_VERSION,
                @ptrCast(&d3d_device),
                null,
                @ptrCast(&d3d_context),
            ))) {
                std.debug.panic(
                    "directx: Error creating device: {}",
                    .{std.os.windows.GetLastError()},
                );
            }
        }

        if (failed(d3d_context.lpVtbl.*.QueryInterface.?(
            d3d_context,
            &d3d.IID_ID3D11DeviceContext1,
            @ptrCast(&d3d_context1),
        ))) {
            std.debug.panic(
                "directx: Error creating device: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        if (builtin.mode == .Debug) {
            var info_queue: *d3d.ID3D11InfoQueue = undefined;
            if (failed(d3d_device.lpVtbl.*.QueryInterface.?(
                d3d_device,
                &d3d.IID_ID3D11InfoQueue,
                @ptrCast(&info_queue),
            ))) {
                std.debug.panic(
                    "directx: Error enabling debugging: {}",
                    .{std.os.windows.GetLastError()},
                );
            }

            _ = info_queue.lpVtbl.*.SetBreakOnSeverity.?(info_queue, d3d.D3D11_MESSAGE_SEVERITY_CORRUPTION, 1);
            _ = info_queue.lpVtbl.*.SetBreakOnSeverity.?(info_queue, d3d.D3D11_MESSAGE_SEVERITY_ERROR, 1);
            _ = info_queue.lpVtbl.*.Release.?(
                info_queue,
            );
        }

        var dxgi_device: *dxgi.IDXGIDevice = undefined;
        if (failed(d3d_device.lpVtbl.*.QueryInterface.?(
            d3d_device,
            &dxgi.IID_IDXGIDevice,
            @ptrCast(&dxgi_device),
        ))) {
            std.debug.panic(
                "directx: Error getting dxgi device: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var dxgi_adapter: *dxgi.IDXGIAdapter = undefined;
        if (failed(dxgi_device.lpVtbl.*.GetAdapter.?(dxgi_device, @ptrCast(&dxgi_adapter)))) {
            std.debug.panic(
                "directx: Error getting dxgi adapter: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var dxgi_factory: *dxgi.IDXGIFactory2 = undefined;
        _ = dxgi_adapter.lpVtbl.*.GetParent.?(dxgi_adapter, &dxgi.IID_IDXGIFactory2, @ptrCast(&dxgi_factory));
        _ = dxgi_adapter.lpVtbl.*.Release.?(dxgi_adapter);
        _ = dxgi_device.lpVtbl.*.Release.?(dxgi_device);

        const swapchain_desc = dxgi.DXGI_SWAP_CHAIN_DESC1{
            .Format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            .SampleDesc = dxgi.DXGI_SAMPLE_DESC{
                .Count = 1,
                .Quality = 0,
            },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT | dxgi.DXGI_USAGE_UNORDERED_ACCESS,
            .BufferCount = 2,
            .Scaling = dxgi.DXGI_SCALING_NONE,
            .SwapEffect = dxgi.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .AlphaMode = dxgi.DXGI_ALPHA_MODE_IGNORE,
            .Flags = dxgi.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
        };

        var swapchain1: *dxgi.IDXGISwapChain1 = undefined;
        if (failed(dxgi_factory.lpVtbl.*.CreateSwapChainForHwnd.?(
            dxgi_factory,
            @ptrCast(d3d_device),
            hwnd,
            &swapchain_desc,
            null,
            null,
            @ptrCast(&swapchain1),
        ))) {
            std.debug.panic(
                "directx: Error creating swapchain {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var dxgi_swapchain: *dxgi.IDXGISwapChain2 = undefined;
        if (failed(swapchain1.lpVtbl.*.QueryInterface.?(
            swapchain1,
            &dxgi.IID_IDXGISwapChain2,
            @ptrCast(&dxgi_swapchain),
        ))) {
            std.debug.panic(
                "directx: Error creating swapchain {}",
                .{std.os.windows.GetLastError()},
            );
        }

        const dxgi_waitable_handle = dxgi_swapchain.lpVtbl.*.GetFrameLatencyWaitableObject.?(
            dxgi_swapchain,
        );

        _ = dxgi_factory.lpVtbl.*.MakeWindowAssociation.?(dxgi_factory, hwnd, dxgi.DXGI_MWA_NO_ALT_ENTER | dxgi.DXGI_MWA_NO_WINDOW_CHANGES);
        _ = swapchain1.lpVtbl.*.Release.?(swapchain1);

        const cell_buffer_count: u32 = 1024;
        const cell_buffer = create_buffer(
            d3d_device,
            d3d.D3D11_BUFFER_DESC{
                .ByteWidth = 1024 * @sizeOf(ScreenCell),
                .Usage = d3d.D3D11_USAGE_DYNAMIC,
                .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE,
                .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
                .MiscFlags = d3d.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                .StructureByteStride = @sizeOf(ScreenCell),
            },
            false,
        );
        set_debug_name(cell_buffer.buffer, "OgCellBuffer");

        const parameter_buffer = create_buffer(
            d3d_device,
            d3d.D3D11_BUFFER_DESC{
                .ByteWidth = @sizeOf(ShaderParameters),
                .Usage = d3d.D3D11_USAGE_DYNAMIC,
                .BindFlags = d3d.D3D11_BIND_CONSTANT_BUFFER,
                .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
            },
            false,
        );

        const glyph_render_textre = create_texture(
            d3d_device,
            1024,
            1024,
            dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            d3d.D3D11_BIND_SHADER_RESOURCE | d3d.D3D11_BIND_RENDER_TARGET,
            false,
        );
        const glyph_sample_texture = create_texture(
            d3d_device,
            1024,
            1024,
            dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
            d3d.D3D11_BIND_SHADER_RESOURCE,
            false,
        );

        const dpi = win32.GetDpiForWindow(hwnd);
        const glyph_renderer = GlyphRenderer.new(dpi, glyph_render_textre, glyph_sample_texture);

        var shader_code: *d3d.ID3DBlob = undefined;
        var shader_errors: *d3d.ID3DBlob = undefined;
        if (failed(d3d.D3DCompile(
            compute_shader_source.ptr,
            compute_shader_source.len,
            "shader.hlsl",
            null,
            null,
            "ComputeMain",
            "cs_5_0",
            0,
            0,
            @ptrCast(&shader_code),
            @ptrCast(&shader_errors),
        ))) {
            var error_slice: []const u8 = undefined;
            error_slice.ptr = @ptrCast(shader_errors.lpVtbl.*.GetBufferPointer.?(shader_errors));
            error_slice.len = shader_errors.lpVtbl.*.GetBufferSize.?(shader_errors);
            std.debug.panic("Error compiling d3d shaders:\n{s}", .{error_slice});
        }
        var compute_shader: *d3d.ID3D11ComputeShader = undefined;
        if (failed(d3d_device.lpVtbl.*.CreateComputeShader.?(
            d3d_device,
            shader_code.lpVtbl.*.GetBufferPointer.?(shader_code),
            shader_code.lpVtbl.*.GetBufferSize.?(shader_code),
            null,
            @ptrCast(&compute_shader),
        ))) {
            std.debug.panic(
                "directx: Failed to compile compute shader: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        return Renderer{
            .hwnd = hwnd,
            .d3d_device = d3d_device,
            .d3d_context = d3d_context1,
            .dxgi_factory = dxgi_factory,
            .dxgi_swapchain = dxgi_swapchain,
            .dxgi_waitable_handle = dxgi_waitable_handle,
            .compute_shader = compute_shader,
            .uav = null,
            .parameter_buffer = parameter_buffer,
            .cell_width = CELL_WIDTH,
            .cell_height = CELL_HEIGHT,
            .terminal_width = 0,
            .terminal_height = 0,
            .cell_buffer_mapped = null,
            .cell_buffer_count = cell_buffer_count,
            .cell_buffer = cell_buffer,
            .cell_count_x = 0,
            .cell_count_y = 0,
            .glyph_renderer = glyph_renderer,
            .config = config,
        };
    }

    pub fn create_buffer(
        d3d_device: *d3d.ID3D11Device,
        desc: d3d.D3D11_BUFFER_DESC,
        uav: bool,
    ) DirectxBuffer {
        var actual_desc = desc;
        if ((actual_desc.BindFlags & d3d.D3D11_BIND_CONSTANT_BUFFER) > 0) {
            actual_desc.ByteWidth = (actual_desc.ByteWidth + 15) & ~@as(u32, 15);
        }

        var buffer: *d3d.ID3D11Buffer = undefined;
        if (failed(d3d_device.lpVtbl.*.CreateBuffer.?(d3d_device, &actual_desc, null, @ptrCast(&buffer)))) {
            std.debug.panic(
                "directx: Error creating buffer: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var uav_: *d3d.ID3D11UnorderedAccessView = undefined;
        var srv: *d3d.ID3D11ShaderResourceView = undefined;

        if ((actual_desc.BindFlags & d3d.D3D11_BIND_CONSTANT_BUFFER) > 0) {
            return DirectxBuffer{
                .buffer = buffer,
                .uav = null,
                .srv = null,
            };
        }

        if (uav) {
            if (failed(d3d_device.lpVtbl.*.CreateUnorderedAccessView.?(d3d_device, @ptrCast(buffer), null, @ptrCast(&uav_)))) {
                std.debug.panic(
                    "directx: Error creating buffer uav: {}",
                    .{std.os.windows.GetLastError()},
                );
            }
            return DirectxBuffer{
                .buffer = buffer,
                .uav = uav_,
                .srv = null,
            };
        } else {
            if (failed(d3d_device.lpVtbl.*.CreateShaderResourceView.?(d3d_device, @ptrCast(buffer), null, @ptrCast(&srv)))) {
                std.debug.panic(
                    "directx: Error creating buffer srv: {}",
                    .{std.os.windows.GetLastError()},
                );
            }
            return DirectxBuffer{
                .buffer = buffer,
                .uav = null,
                .srv = srv,
            };
        }
    }

    pub fn create_texture(
        d3d_device: *d3d.ID3D11Device,
        width: u32,
        height: u32,
        format: dxgi.DXGI_FORMAT,
        flags: u32,
        uav: bool,
    ) DirectxTexture {
        var desc = d3d.D3D11_TEXTURE2D_DESC{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = dxgi.DXGI_SAMPLE_DESC{
                .Count = 1,
                .Quality = 0,
            },
            .Usage = d3d.D3D11_USAGE_DEFAULT,
            .BindFlags = flags,
        };

        if (uav) {
            desc.BindFlags |= d3d.D3D11_BIND_UNORDERED_ACCESS;
        }

        var texture: *d3d.ID3D11Texture2D = undefined;
        if (failed(d3d_device.lpVtbl.*.CreateTexture2D.?(d3d_device, &desc, null, @ptrCast(&texture)))) {
            std.debug.panic(
                "directx: Error creating glyph render surface: {}",
                .{std.os.windows.GetLastError()},
            );
        }
        var surface: *dxgi.IDXGISurface = undefined;
        if (failed(texture.lpVtbl.*.QueryInterface.?(
            texture,
            &dxgi.IID_IDXGISurface,
            @ptrCast(&surface),
        ))) {
            std.debug.panic(
                "directx: Error creating glyph render surface: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var uav_: *d3d.ID3D11UnorderedAccessView = undefined;
        var srv: *d3d.ID3D11ShaderResourceView = undefined;

        if (uav) {
            if (failed(d3d_device.lpVtbl.*.CreateUnorderedAccessView.?(d3d_device, @ptrCast(texture), null, @ptrCast(&uav_)))) {
                std.debug.panic(
                    "directx: Error creating texture uav: {}",
                    .{std.os.windows.GetLastError()},
                );
            }
            return DirectxTexture{
                .texture = texture,
                .surface = surface,
                .uav = uav_,
                .srv = null,
            };
        } else {
            if (failed(d3d_device.lpVtbl.*.CreateShaderResourceView.?(d3d_device, @ptrCast(texture), null, @ptrCast(&srv)))) {
                std.debug.panic(
                    "directx: Error creating texture srv: {}",
                    .{std.os.windows.GetLastError()},
                );
            }
            return DirectxTexture{
                .texture = texture,
                .surface = surface,
                .uav = null,
                .srv = srv,
            };
        }
    }

    pub fn draw(self: *@This()) void {
        self.d3d_context.lpVtbl.*.ClearUnorderedAccessViewFloat.?(self.d3d_context, self.uav, &[_]f32{ 1.0, 0.0, 0.0, 1.0 });

        self.d3d_context.lpVtbl.*.CSSetConstantBuffers.?(self.d3d_context, 0, 1, &self.parameter_buffer.buffer);
        const srvs: []const *d3d.ID3D11ShaderResourceView = &.{
            self.cell_buffer.srv.?,
            self.glyph_renderer.glyph_sample_texture.srv.?,
        };
        self.d3d_context.lpVtbl.*.CSSetShaderResources.?(self.d3d_context, 0, @intCast(srvs.len), srvs.ptr);
        self.d3d_context.lpVtbl.*.CSSetUnorderedAccessViews.?(self.d3d_context, 0, 1, &self.uav, null);
        self.d3d_context.lpVtbl.*.CSSetShader.?(self.d3d_context, self.compute_shader, null, 0);
        self.d3d_context.lpVtbl.*.Dispatch.?(
            self.d3d_context,
            (self.terminal_width + 7) / 8,
            (self.terminal_height + 7) / 8,
            1,
        );

        _ = self.dxgi_swapchain.lpVtbl.*.Present.?(self.dxgi_swapchain, 0, 0);
    }

    pub fn transfer(self: *const @This(), index: GpuIndex) void {
        const src_box = d3d.D3D11_BOX{
            .left = 0,
            .right = self.cell_width,
            .top = 0,
            .bottom = self.cell_height,
            .front = 0,
            .back = 1,
        };
        // const (x, y) = index.?;

        self.d3d_context.lpVtbl.*.CopySubresourceRegion.?(
            self.d3d_context,
            @ptrCast(self.glyph_renderer.glyph_sample_texture.texture),
            0,
            index.x * self.cell_width,
            index.y * self.cell_height,
            0,
            @ptrCast(self.glyph_renderer.render_target_texture.texture),
            0,
            &src_box,
        );
    }

    pub fn place_cursor(self: *@This(), x: u32, y: u32, kind: CursorKind) void {
        // const mapped = self
        //     .parameter_buffer
        //     .map_one::<ShaderParameters>(self.d3d_context);
        // mapped.cursor_x = x;
        // mapped.cursor_y = y;
        // mapped.cursor_kind = match kind {
        //     CursorKind::Block => 0,
        //     CursorKind::Bar => 1,
        //     CursorKind::Underline => 2,
        //     CursorKind::Hidden => 3,
        // };
        // self.parameter_buffer.unmap(self.d3d_context);

        const cells = self
            .cell_buffer_mapped
            .expect("Call start_glyph_placement before this");

        const cell = cells[@as(usize, y) * @as(usize, self.cell_count_x) + @as(usize, x)];

        cell.curosr_kind = switch (kind) {
            .Hidden => 0,
            .Block => 1,
            .Bar => 2,
            .Underline => 3,
        };
    }

    pub fn set_cursor_style(self: *@This(), style: Style) void {
        {
            const mapped = self
                .parameter_buffer
                .map_one(self.d3d_context, ShaderParameters);
            mapped.cursor_foreground = style.fg.toPacked();
            mapped.cursor_background = style.bg.toPacked();
            // mapped.cursor_foreground = color_to_packed_u32(Color::Cyan);
            // mapped.cursor_background = color_to_packed_u32(Color::Cyan);
            self.parameter_buffer.unmap(self.d3d_context);
        }
    }

    pub fn start_glyph_placement(self: *@This()) void {
        const cells = self
            .cell_buffer
            .map(self.d3d_context, ScreenCell, @as(usize, self.cell_buffer_count));

        self.cell_buffer_mapped = cells;
    }

    pub fn place_glyph(
        self: *@This(),
        x: u16,
        y: u16,
        string: []const u16,
        foreground: Color,
        background: Color,
        underline_color: Color,
        underline_style: UnderlineStyle,
    ) void {
        const cells = self
            .cell_buffer_mapped
            orelse @panic("Call start_glyph_placement before this");

        if (string[0] >= DIRECT_CODEPOINT_MIN and string[0] <= DIRECT_CODEPOINT_MAX) {
            const glyph_gpu_index = self.glyph_renderer.direct_codepoint_table[@as(usize, string[0]) - DIRECT_CODEPOINT_MIN];

            const cell = &cells[@as(usize, y) * @as(usize, self.cell_count_x) + @as(usize, x)];
            cell.gpu_index = glyph_gpu_index;
            cell.foreground = foreground.toPacked();
            cell.background = background.toPacked();

            cell.underline = underline_color.toPacked();
            cell.underline = (cell.underline & 0xffffff) | (@intFromEnum(underline_style) << 24);
        } else {
            // todo!();
        }
    }

    pub fn end_glyph_placement(self: *@This()) void {
        self.cell_buffer.unmap(self.d3d_context);
        self.cell_buffer_mapped = null;
    }

    pub fn calculate_cell_count(self: *const @This(), width: u32, height: u32) struct { u32, u32 } {
        const cell_width, const cell_height = self.glyph_renderer.calculate_cell_size();
        return .{ width / cell_width, height / cell_height };
    }

    pub fn resize_if_needed(self: *@This(), width: u32, height: u32) void {
        if (width == self.terminal_width and height == self.terminal_height) {
            return;
        }

        self.terminal_width = width;
        self.terminal_height = height;

        self.refresh();
    }

    pub fn reconfigure(self: @This(), config: anytype) void {
        self.config = config;
        self.refresh();
    }

    pub fn refresh(self: *@This()) void {
        if (self.config.gui_font_family.len == 0) {
            self.config.gui_font_family = "Consolas";
        }
        std.debug.print("refresh: {s} {}\n", .{ self.config.gui_font_family, self.config.gui_font_size });

        self.glyph_renderer.set_font(self.config.gui_font_family, self.config.gui_font_size);

        const font_metrics = self.glyph_renderer.get_font_metrics();

        const cell_width, const cell_height = self.glyph_renderer.calculate_cell_size();
        self.cell_width = cell_width;
        self.cell_height = cell_height;

        const render_width = 1024;
        const render_height = 1024;
        const tile_count_x = render_width / self.cell_width;
        const tile_count_y = render_height / self.cell_height;
        _ = tile_count_y;

        // self.glyph_renderer.glyph_cache = GlyphCache.new(1024, 1024, tile_count_x, tile_count_y);
        self.glyph_renderer.direct_codepoint_table =
            GlyphCache.new_direct_codepoint_table(tile_count_x);

        for (DIRECT_CODEPOINT_MIN..DIRECT_CODEPOINT_MAX + 1) |index| {
            self.glyph_renderer.draw_text(&.{@intCast(index)});
            self.transfer(
                self.glyph_renderer.direct_codepoint_table[index - DIRECT_CODEPOINT_MIN],
            );
        }

        self.cell_count_x = self.terminal_width / self.cell_width;
        self.cell_count_y = self.terminal_height / self.cell_height;

        const cell_count = self.cell_count_x * self.cell_count_y;
        if (cell_count >= self.cell_buffer_count) {
            const new_cell_count = cell_count;
            const new_cell_buffer =
                create_buffer(
                    self.d3d_device,
                    d3d.D3D11_BUFFER_DESC{
                        .ByteWidth = new_cell_count * @sizeOf(ScreenCell),
                        .Usage = d3d.D3D11_USAGE_DYNAMIC,
                        .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE,
                        .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
                        .MiscFlags = d3d.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                        .StructureByteStride = @sizeOf(ScreenCell),
                    },
                    false,
                );
            set_debug_name(new_cell_buffer.buffer, "NewCellBuffer");

            self.d3d_context.lpVtbl.*.CopySubresourceRegion.?(
                self.d3d_context,
                @ptrCast(new_cell_buffer.buffer),
                0,
                0,
                0,
                0,
                @ptrCast(self.cell_buffer.buffer),
                0,
                null,
            );

            self.cell_buffer.deinit();
            self.cell_buffer = new_cell_buffer;
            self.cell_buffer_count = new_cell_count;
        }

        self.d3d_context.lpVtbl.*.ClearState.?(self.d3d_context);
        if (self.uav != null) {
            _ = self.uav.?.lpVtbl.*.Release.?(self.uav.?);
        }
        self.d3d_context.lpVtbl.*.Flush.?(self.d3d_context);

        var hr = self.dxgi_swapchain.lpVtbl.*.ResizeBuffers.?(
            self.dxgi_swapchain,
            0,
            self.terminal_width,
            self.terminal_height,
            dxgi.DXGI_FORMAT_UNKNOWN,
            dxgi.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
        );
        std.debug.assert(success(hr));

        var buffer: *d3d.ID3D11Texture2D = undefined;
        hr = self.dxgi_swapchain.lpVtbl.*.GetBuffer.?(
            self.dxgi_swapchain,
            0,
            &d3d.IID_ID3D11Texture2D,
            @ptrCast(&buffer),
        );
        std.debug.assert(success(hr));

        hr = self.d3d_device.lpVtbl.*.CreateUnorderedAccessView.?(
            self.d3d_device,
            @ptrCast(buffer),
            null,
            &self.uav,
        );
        std.debug.assert(success(hr));
        _ = buffer.lpVtbl.*.Release.?(buffer);

        {
            const mapped = self
                .parameter_buffer
                .map_one(self.d3d_context, ShaderParameters);
            mapped.cell_width = self.cell_width;
            mapped.cell_height = self.cell_height;
            mapped.terminal_width = self.terminal_width / self.cell_width;
            mapped.terminal_height = self.terminal_height / self.cell_height;

            const descent = @divTrunc(
                @divTrunc(
                    @as(i64, font_metrics.descent) * @as(i64, self.config.gui_font_size) * @as(i64, self.glyph_renderer.dpi),
                    96,
                ),
                @as(i64, font_metrics.designUnitsPerEm),
            );
            const underline_position = @divTrunc(
                @divTrunc(
                    @as(i64, font_metrics.underlinePosition) * @as(i64, self.config.gui_font_size) * @as(i64, self.glyph_renderer.dpi),
                    96,
                ),
                @as(i64, font_metrics.designUnitsPerEm),
            );
            const underline_size = @divTrunc(
                @divTrunc(
                    @as(i64, font_metrics.underlineThickness) * @as(i64, self.config.gui_font_size) * @as(i64, self.glyph_renderer.dpi),
                    96,
                ),
                @as(i64, font_metrics.designUnitsPerEm),
            );

            std.debug.print("{} {} {} - {}    {}\n", .{ underline_position, self.cell_height, descent, (underline_position + @as(i64, self.cell_height) - descent), underline_size });

            mapped.underline_position_and_thickness =
                @as(u32, @intCast((-underline_position + @as(i64, self.cell_height) - descent))) | @as(u32, @intCast(((underline_size) << 16)));
            self.parameter_buffer.unmap(self.d3d_context);
        }
    }
};

const ShaderParameters = extern struct {
    cell_width: u32,
    cell_height: u32,
    terminal_width: u32,
    terminal_height: u32,
    cursor_foreground: u32,
    cursor_background: u32,
    underline_position_and_thickness: u32,
    strikethrough_position_and_thickness: u32,
};

const ScreenCell = extern struct {
    gpu_index: GpuIndex,
    foreground: u32,
    background: u32,
    curosr_kind: u32,
    underline: u32,
};

pub inline fn success(hr: win32.HRESULT) bool {
    return hr >= 0;
}

pub inline fn failed(hr: win32.HRESULT) bool {
    return hr < 0;
}

const DXGI_MWA_NO_WINDOW_CHANGES: u32 = 1 << 0;
const DXGI_MWA_NO_ALT_ENTER: u32 = 1 << 1;
const DXGI_MWA_NO_PRINT_SCREEN: u32 = 1 << 2;

const GlyphRenderer = struct {
    dpi: u32,
    dwrite_factory: *dwrite.IDWriteFactory,
    render_target_texture: DirectxTexture,
    render_target: *d2d.ID2D1RenderTarget,
    brush: *d2d.ID2D1Brush,

    glyph_sample_texture: DirectxTexture,

    text_format: ?*dwrite.IDWriteTextFormat,

    glyph_cache: GlyphCache,
    direct_codepoint_table: DirectCodepointTable,

    pub fn new(
        dpi: u32,
        glyph_surface: DirectxTexture,
        glyph_sample_texture: DirectxTexture,
    ) GlyphRenderer {
        var factory: *d2d.ID2D1Factory = undefined;
        if (failed(d2d.D2D1CreateFactory(
            d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
            &d2d.IID_ID2D1Factory3,
            null,
            @ptrCast(&factory),
        ))) {
            std.debug.panic(
                "directx: Error initializing direct2d: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        const render_target_properties = d2d.D2D1_RENDER_TARGET_PROPERTIES{
            .type = d2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = d2d.D2D1_PIXEL_FORMAT{
                .format = dxgi.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = dxgi.DXGI_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpiX = 0.0,
            .dpiY = 0.0,
            .usage = d2d.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = d2d.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        var render_target: *d2d.ID2D1RenderTarget = undefined;
        if (failed(factory.lpVtbl.*.CreateDxgiSurfaceRenderTarget.?(
            factory,
            glyph_surface.surface,
            &render_target_properties,
            @ptrCast(&render_target),
        ))) {
            std.debug.panic(
                "directx: Error creating direct2d render target: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        const brush_color = d2d.D2D1_COLOR_F{
            .r = 1.0,
            .g = 1.0,
            .b = 1.0,
            .a = 1.0,
        };

        var brush: *d2d.ID2D1Brush = undefined;
        _ = render_target.lpVtbl.*.CreateSolidColorBrush.?(
            render_target,
            &brush_color,
            null,
            @ptrCast(&brush),
        );
        _ = factory.lpVtbl.*.Base.Release.?(
            @ptrCast(factory),
        );

        var dwrite_factory: *dwrite.IDWriteFactory = undefined;
        if (failed(dwrite.DWriteCreateFactory(
            dwrite.DWRITE_FACTORY_TYPE_SHARED,
            &dwrite.IID_IDWriteFactory,
            @ptrCast(&dwrite_factory),
        ))) {
            std.debug.panic(
                "directx: Error initializing dwrite: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        return GlyphRenderer{
            .dpi = dpi,
            .render_target_texture = glyph_surface,
            .glyph_sample_texture = glyph_sample_texture,
            // .glyph_cache = GlyphCache.new(1024, 1024, 1024, 1024),
            .glyph_cache = undefined,
            .direct_codepoint_table = GlyphCache.new_direct_codepoint_table(1024),
            .dwrite_factory = dwrite_factory,
            .render_target = render_target,
            .brush = brush,
            .text_format = null,
        };
    }

    pub fn get_font_metrics(self: *const @This()) dwrite.DWRITE_FONT_METRICS {
        var collection: *dwrite.IDWriteFontCollection = undefined;
        const text_format = self.text_format.?;

        _ = text_format.lpVtbl.*.GetFontCollection.?(text_format, @ptrCast(&collection));
        var family_name: [1024]u16 = std.mem.zeroes([1024]u16);
        _ = text_format.lpVtbl.*.GetFontFamilyName.?(text_format, &family_name[0], family_name.len);

        var index: u32 = 0;
        var exists: i32 = 0;
        _ = collection.lpVtbl.*.FindFamilyName.?(collection, &family_name[0], &index, &exists);

        var font_family: *dwrite.IDWriteFontFamily = undefined;
        _ = collection.lpVtbl.*.GetFontFamily.?(collection, index, @ptrCast(&font_family));

        var font: *dwrite.IDWriteFont = undefined;
        _ = font_family.lpVtbl.*.GetFirstMatchingFont.?(
            font_family,
            text_format.lpVtbl.*.GetFontWeight.?(text_format),
            text_format.lpVtbl.*.GetFontStretch.?(text_format),
            text_format.lpVtbl.*.GetFontStyle.?(text_format),
            @ptrCast(&font),
        );

        var font_metrics = std.mem.zeroes(dwrite.DWRITE_FONT_METRICS);
        _ = font.lpVtbl.*.GetMetrics.?(font, &font_metrics);

        return font_metrics;
    }

    pub fn calculate_cell_size(self: *const @This()) struct { u32, u32 } {
        var width, var height = self.get_metrics(&.{@as(u16, 'M')});
        const width1, const height1 = self.get_metrics(&.{@as(u16, 'g')});
        width = @max(width, width1);
        height = @max(height, height1);
        return .{ width, height };
    }

    pub fn get_metrics(self: *const @This(), string: []const u16) struct { u32, u32 } {
        if (self.text_format == null) {
            std.debug.panic(
                "directx: please call set_font before drawing",
                .{},
            );
        }

        var text_layout: *dwrite.IDWriteTextLayout = undefined;
        if (failed(self.dwrite_factory.lpVtbl.*.CreateTextLayout.?(
            self.dwrite_factory,
            string.ptr,
            @intCast(string.len),
            self.text_format,
            1024.0,
            1024.0,
            @ptrCast(&text_layout),
        ))) {
            std.debug.panic(
                "directx: Error getting text metrics: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        var metrics = std.mem.zeroes(dwrite.DWRITE_TEXT_METRICS);
        _ = text_layout.lpVtbl.*.GetMetrics.?(text_layout, &metrics);
        _ = text_layout.lpVtbl.*.Release.?(text_layout);
        std.debug.assert(metrics.left == 0.0);
        std.debug.assert(metrics.top == 0.0);

        return .{ @intFromFloat(metrics.width + 0.5), @intFromFloat(metrics.height + 0.5) };
    }

    pub fn set_font(self: *@This(), font_name: []const u8, font_height: u32) void {
        var font_name_buf = std.mem.zeroes([512]u16);
        const font_name_utf16_len = std.unicode.utf8ToUtf16Le(&font_name_buf, font_name) catch @panic("Error encoding utf16");
        std.debug.assert(font_name_utf16_len < font_name_buf.len);
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

        // std.debug.assert(self.dwrite_factory != null);
        if (failed(self.dwrite_factory.lpVtbl.*.CreateTextFormat.?(
            self.dwrite_factory,
            &font_name_buf,
            null,
            dwrite.DWRITE_FONT_WEIGHT_REGULAR,
            dwrite.DWRITE_FONT_STYLE_NORMAL,
            dwrite.DWRITE_FONT_STRETCH_NORMAL,
            @floatFromInt(font_height * self.dpi / 96),
            locale,
            @ptrCast(&self.text_format),
        ))) {
            std.debug.panic(
                "directx: Error setting dwrite font: {}",
                .{std.os.windows.GetLastError()},
            );
        }

        _ = self.text_format.?.lpVtbl.*.SetTextAlignment.?(self.text_format.?, dwrite.DWRITE_TEXT_ALIGNMENT_LEADING);
        _ = self.text_format.?.lpVtbl.*.SetParagraphAlignment.?(self.text_format.?, dwrite.DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
    }

    pub fn draw_text(self: @This(), text: []const u16) void {
        if (self.text_format == null) {
            std.debug.panic("directx: please call set_font before drawing", .{});
        }

        const rect = d2d.D2D_RECT_F{
            .left = 0.0,
            .top = 0.0,
            .right = 1024.0,
            .bottom = 1024.0,
        };

        const clear_color = d2d.D2D1_COLOR_F{
            .r = 0.0,
            .g = 0.0,
            .b = 0.0,
            .a = 0.0,
        };

        self.render_target.lpVtbl.*.BeginDraw.?(self.render_target);
        self.render_target.lpVtbl.*.Clear.?(self.render_target, &clear_color);
        self.render_target.lpVtbl.*.DrawTextA.?(
            self.render_target,
            text.ptr,
            @intCast(text.len),
            self.text_format,
            &rect,
            self.brush,
            d2d.D2D1_DRAW_TEXT_OPTIONS_CLIP | d2d.D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT,
            dwrite.DWRITE_MEASURING_MODE_NATURAL,
        );
        _ = self.render_target.lpVtbl.*.EndDraw.?(self.render_target, null, null);
    }
};

// pub fn utf16(s: &str) Vec<u16> {
//     var result: Vec<u16> = s.encode_utf16().collect();
//     result.push(0);
//     return result;
// }
